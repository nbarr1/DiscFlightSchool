package com.discflightschool.core.tracking

import com.discflightschool.core.detection.DetectionCancelledException
import com.discflightschool.core.detection.DiscDetection
import com.discflightschool.core.detection.FlightTrackingResult
import com.discflightschool.core.detection.Trajectory
import kotlin.coroutines.cancellation.CancellationException
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.roundToLong
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.supervisorScope
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull

/** One frame of the server's track. Every value is a fraction of the frame; `x`/`y` is the box center. */
data class CloudTrackPoint(
    val frame: Int,
    val timeMs: Long,
    val x: Double,
    val y: Double,
    val width: Double,
    val height: Double,
    val confidence: Double,
)

/**
 * What `GET /api/disc-flight/jobs/{id}/track` returns: the Roboflow Workflow's
 * best disc box in each frame of the processed range, at the video's own
 * frame rate. Frame 0 and [CloudTrackPoint.timeMs] 0 are the start of that
 * range, which the app sets to the trim start.
 */
data class CloudTrack(
    val fps: Double,
    val frameCount: Int,
    val points: List<CloudTrackPoint>,
) {
    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        /**
         * Parse the endpoint's JSON body. A point with a missing field, or a
         * position outside the frame, is skipped rather than failing the
         * whole track.
         *
         * @throws IllegalArgumentException when [body] is not a track at all.
         */
        fun parse(body: String): CloudTrack {
            val root = runCatching { json.parseToJsonElement(body) as? JsonObject }.getOrNull()
                ?: throw IllegalArgumentException("The server returned an unexpected track.")
            val fps = root.number("fps")?.takeIf { it > 0 }
                ?: throw IllegalArgumentException("The server's track has no frame rate.")
            val detections = root["detections"] as? JsonArray
                ?: throw IllegalArgumentException("The server's track has no detections list.")
            val points = detections.mapNotNull { element ->
                val point = element as? JsonObject ?: return@mapNotNull null
                val frame = point.number("frame")?.takeIf { it >= 0 }?.roundToInt()
                    ?: return@mapNotNull null
                CloudTrackPoint(
                    frame = frame,
                    timeMs = point.number("timeMs")?.roundToLong()
                        ?: (frame * 1000.0 / fps).roundToLong(),
                    x = point.fraction("x") ?: return@mapNotNull null,
                    y = point.fraction("y") ?: return@mapNotNull null,
                    width = point.fraction("width") ?: return@mapNotNull null,
                    height = point.fraction("height") ?: return@mapNotNull null,
                    confidence = point.fraction("confidence") ?: return@mapNotNull null,
                )
            }
            return CloudTrack(
                fps = fps,
                frameCount = root.number("frameCount")?.roundToInt() ?: 0,
                points = points,
            )
        }

        private fun JsonObject.number(key: String): Double? =
            (this[key] as? JsonPrimitive)?.takeUnless { it.isString }?.doubleOrNull?.takeIf { it.isFinite() }

        private fun JsonObject.fraction(key: String): Double? = number(key)?.takeIf { it in 0.0..1.0 }
    }
}

/** Where [CloudDiscTracker] gets its track. The app's `DiscFlightClient` implements it over HTTP. */
interface CloudTrackSource {
    /**
     * Run [startMs] to [endMs] (null for the end of the file) of [videoPath]
     * through the server's Roboflow Workflow and return its track.
     *
     * [onProgress] receives a 0-1 fraction when the server knows the frame
     * total, or null when it doesn't, and a status line to show.
     */
    suspend fun fetchTrack(
        videoPath: String,
        startMs: Long,
        endMs: Long?,
        onProgress: (Double?, String) -> Unit,
    ): CloudTrack
}

/**
 * The automatic tracker that uses the server's Roboflow Workflow instead of
 * the on-device detector.
 *
 * The server processes the trimmed range at the video's own frame rate. This
 * maps its positions onto the session's frames, then runs the same coherence
 * filter, smoothing, and gap filling as the on-device pipeline, so the two
 * produce results of the same shape.
 */
class CloudDiscTracker(
    private val source: CloudTrackSource,
    private val onProgress: (Double?, String) -> Unit = { _, _ -> },
) : DiscTracker {

    @Volatile
    override var progress: Double = 0.0
        private set

    @Volatile
    override var statusMessage: String = ""
        private set

    @Volatile private var running: Job? = null
    @Volatile private var cancelRequested = false

    override suspend fun track(
        session: TrackerSession,
        // Ignored, as for the on-device automatic tracker.
        seedPoints: List<TrackerSeedPoint>,
    ): FlightTrackingResult {
        cancelRequested = false
        progress = 0.0
        val track = try {
            // The fetch runs as its own child so that cancel() can stop it
            // (and the upload in flight) without cancelling the caller.
            supervisorScope {
                val fetch = async {
                    source.fetchTrack(session.videoPath, session.trimStartMs, session.trimEndMs) { fraction, status ->
                        if (fraction != null) progress = fraction.coerceIn(0.0, 1.0)
                        statusMessage = status
                        onProgress(fraction, status)
                    }
                }
                running = fetch
                if (cancelRequested) fetch.cancel()
                fetch.await()
            }
        } catch (e: CancellationException) {
            if (cancelRequested && currentCoroutineContext().isActive) throw DetectionCancelledException()
            throw e
        } finally {
            running = null
        }
        progress = 1.0
        statusMessage = "Complete!"
        return toFlightResult(track, session)
    }

    /** Stop a [track] call in progress, which then throws [DetectionCancelledException]. */
    fun cancel() {
        cancelRequested = true
        running?.cancel()
    }

    /** Nothing to release: the fetch ends with the [track] call. */
    override fun dispose() = Unit

    companion object {
        /**
         * Map [track] onto [session]'s frames and clean it up as the on-device
         * pipeline does.
         *
         * Several server frames fall on each session frame, since the server
         * works at the video's own rate. The one nearest the session frame's
         * time wins, and the higher confidence breaks a tie.
         */
        fun toFlightResult(track: CloudTrack, session: TrackerSession): FlightTrackingResult {
            val nearest = HashMap<Int, CloudTrackPoint>()
            for (point in track.points) {
                val frame = (point.timeMs * session.fps / 1000.0).roundToInt()
                if (frame !in 0 until session.totalFrames) continue
                val current = nearest[frame]
                if (current == null) {
                    nearest[frame] = point
                    continue
                }
                val target = FrameIndexing.timestampOf(frame, session.fps)
                val offset = abs(point.timeMs - target)
                val currentOffset = abs(current.timeMs - target)
                if (offset < currentOffset || (offset == currentOffset && point.confidence > current.confidence)) {
                    nearest[frame] = point
                }
            }
            val raw = nearest.entries
                .sortedBy { it.key }
                .map { (frame, point) ->
                    DiscDetection(
                        frameIndex = frame,
                        x = point.x,
                        y = point.y,
                        width = point.width,
                        height = point.height,
                        confidence = point.confidence,
                        timestampMs = FrameIndexing.timestampOf(frame, session.fps),
                    )
                }
            val coherent = Trajectory.filterSpatialCoherence(raw, session.totalFrames)
            val smoothed = Trajectory.smoothDetections(coherent, windowSize = 3)
            val filled = Trajectory.interpolateDetections(smoothed, session.fps)
            return FlightTrackingResult(
                detections = filled,
                videoWidth = session.videoWidth,
                videoHeight = session.videoHeight,
                fps = session.fps,
                totalFrames = session.totalFrames,
            )
        }
    }
}
