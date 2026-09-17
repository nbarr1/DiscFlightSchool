package com.discflightschool.core.tracking

import com.discflightschool.core.detection.DiscDetection
import com.discflightschool.core.detection.FlightTrackingResult
import com.discflightschool.core.math.AngleCalculator
import kotlin.math.ceil
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * Frame-index maths shared by the video player and every tracker.
 *
 * Frame index 0 is the first frame at or after the trim start — *not* the start
 * of the file. Both directions live here so the player's live frame counter and
 * a tracker's returned detections cannot drift apart: they did, before this
 * existed, whenever a clip was trimmed.
 */
object FrameIndexing {
    /** The frame index a playback position maps to, relative to [trimStartMs]. */
    fun frameIndexAt(positionMs: Long, trimStartMs: Long, fps: Double): Int =
        ((positionMs - trimStartMs) * fps / 1000.0).roundToInt()

    /** The offset of [frameIndex] from the trim start, in milliseconds. */
    fun timestampOf(frameIndex: Int, fps: Double): Long =
        (frameIndex * 1000.0 / fps).roundToLong()
}

/** A single user-placed seed point marking the disc's position at a frame. */
data class TrackerSeedPoint(
    val frameIndex: Int,
    /** Normalized 0-1. */
    val x: Double,
    /** Normalized 0-1. */
    val y: Double,
)

/** Parameters describing the video being tracked. */
data class TrackerSession(
    val videoPath: String,
    val fps: Double,
    val totalFrames: Int,
    val videoWidth: Double,
    val videoHeight: Double,
    /**
     * The start of the trimmed range, in milliseconds from the start of the file.
     *
     * Frame index 0 is the first frame at or after this point. Every
     * [TrackerSeedPoint.frameIndex], every [DiscDetection.frameIndex] a tracker
     * returns, and the player's own current frame all live in that space. A
     * tracker that extracted frames from the start of the file instead would
     * pair every position with an image from the wrong moment.
     */
    val trimStartMs: Long = 0,
    /** The end of the trimmed range in milliseconds, or null for end-of-file. */
    val trimEndMs: Long? = null,
) {
    /** The frame index a playback position maps to in this session's space. */
    fun frameIndexAt(positionMs: Long): Int =
        FrameIndexing.frameIndexAt(positionMs, trimStartMs, fps)

    /** The offset of [frameIndex] from the trim start. */
    fun timestampOf(frameIndex: Int): Long = FrameIndexing.timestampOf(frameIndex, fps)
}

/**
 * The common contract for turning user-seeded points into a full per-frame
 * flight path.
 *
 * Lets the UI swap tracking strategies — pure geometric spline,
 * detection-refined hybrid, or the fully automatic detector — without changing
 * call sites.
 */
interface DiscTracker {
    /** Progress in 0-1 for the most recent [track] call. */
    val progress: Double

    /** A human-readable status for the most recent [track] call. */
    val statusMessage: String

    /**
     * Build a full per-frame [FlightTrackingResult] from the given seed points,
     * ordered or unordered by frame index.
     */
    suspend fun track(
        session: TrackerSession,
        seedPoints: List<TrackerSeedPoint>,
    ): FlightTrackingResult

    /**
     * Release any resources held by this tracker. Safe to call more than once,
     * and safe to call even if [track] was never invoked.
     */
    fun dispose()
}

/**
 * The default tracker: a pure Catmull-Rom spline through the seed points, with
 * no image analysis. Requires at least two seed points.
 */
class GeometricSplineTracker : DiscTracker {
    override var progress: Double = 0.0
        private set

    override var statusMessage: String = ""
        private set

    override suspend fun track(
        session: TrackerSession,
        seedPoints: List<TrackerSeedPoint>,
    ): FlightTrackingResult {
        require(seedPoints.size >= 2) {
            "GeometricSplineTracker needs at least 2 seed points, got ${seedPoints.size}"
        }

        statusMessage = "Generating spline..."
        progress = 0.0

        val sorted = seedPoints.sortedBy { it.frameIndex }
        val seedFrames = sorted.map { it.frameIndex }.toHashSet()
        val detections = ArrayList<DiscDetection>()

        for (i in 0 until sorted.size - 1) {
            val kfStart = sorted[i]
            val kfEnd = sorted[i + 1]

            val p0 = if (i > 0) sorted[i - 1] else kfStart
            val p3 = if (i < sorted.size - 2) sorted[i + 2] else kfEnd

            val frameSpan = kfEnd.frameIndex - kfStart.frameIndex
            if (frameSpan <= 0) continue

            val isLastSegment = i == sorted.size - 2
            val endF = if (isLastSegment) frameSpan else frameSpan - 1

            for (f in 0..endF) {
                val t = f.toDouble() / frameSpan
                val x = AngleCalculator.catmullRom(p0.x, kfStart.x, kfEnd.x, p3.x, t)
                val y = AngleCalculator.catmullRom(p0.y, kfStart.y, kfEnd.y, p3.y, t)
                val frameIdx = kfStart.frameIndex + f

                detections += DiscDetection(
                    frameIndex = frameIdx,
                    x = x.coerceIn(0.0, 1.0),
                    y = y.coerceIn(0.0, 1.0),
                    width = 0.03,
                    height = 0.03,
                    confidence = if (frameIdx in seedFrames) 1.0 else 0.5,
                    timestampMs = DiscDetection.timestampFor(frameIdx, session.fps),
                )
            }

            progress = (i + 1).toDouble() / (sorted.size - 1)
        }

        progress = 1.0
        statusMessage = "Complete!"

        return FlightTrackingResult(
            detections = detections,
            videoWidth = session.videoWidth,
            videoHeight = session.videoHeight,
            fps = session.fps,
            totalFrames = session.totalFrames,
        )
    }

    override fun dispose() = Unit
}

/**
 * What [AutoDiscTracker] needs from the platform detector, so the tracker's own
 * behaviour is testable without TFLite or a video file.
 */
interface VideoDiscDetector {
    val progress: Double
    val statusMessage: String

    /** Load the detector model, throwing if it cannot be loaded at all. */
    suspend fun loadModel()

    suspend fun processVideo(
        videoPath: String,
        fps: Double,
        maxFrames: Int,
        startMs: Long,
        endMs: Long?,
    ): FlightTrackingResult
}

/**
 * The fully automatic tracker: finds the disc with no user input at all.
 *
 * Delegates to the detector's track-by-detection pipeline, which discovers the
 * disc with a full-frame scan and then follows it frame-to-frame in a predicted
 * search window.
 */
class AutoDiscTracker(private val detector: VideoDiscDetector) : DiscTracker {

    override val progress: Double get() = detector.progress

    override val statusMessage: String get() = detector.statusMessage

    override suspend fun track(
        session: TrackerSession,
        // Ignored — this tracker discovers the disc itself. Callers pass an empty list.
        seedPoints: List<TrackerSeedPoint>,
    ): FlightTrackingResult {
        // Load explicitly rather than leaning on a lazy load inside the
        // pipeline, so a model that cannot load is reported as its own distinct
        // failure instead of surfacing as an anonymous exception partway
        // through a run.
        try {
            detector.loadModel()
        } catch (e: Throwable) {
            throw com.discflightschool.core.detection.DetectorModelUnavailableException(e)
        }

        val result = detector.processVideo(
            videoPath = session.videoPath,
            fps = session.fps,
            maxFrames = framesForSession(session),
            startMs = session.trimStartMs,
            endMs = session.trimEndMs,
        )

        // The pipeline reports the dimensions of its decoded working frames —
        // downscaled during extraction — not the video the player is showing.
        // Re-state the session's own dimensions so anything reading these
        // fields is not quietly handed the extraction resolution.
        return FlightTrackingResult(
            detections = result.detections,
            videoWidth = session.videoWidth,
            videoHeight = session.videoHeight,
            fps = result.fps,
            totalFrames = result.totalFrames,
        )
    }

    /**
     * Deliberately empty.
     *
     * The detector is app-scoped, while call sites dispose trackers in a
     * `finally`. Forwarding this would close the shared TFLite interpreter for
     * the rest of the app session. Unlike the hybrid tracker, this one
     * constructs nothing of its own that needs releasing.
     */
    override fun dispose() = Unit

    companion object {
        /** An upper bound on the frames processed in one run. */
        const val MAX_PROCESSED_FRAMES = 300

        /**
         * How many frames to process for [session], derived from the trimmed
         * span rather than taking the 300-frame default.
         *
         * A six-second trim at 10fps is about 61 frames; processing 300 would
         * spend five times as long walking past the end of the clip — and at
         * this model's input size, every frame costs real wall-clock time.
         */
        fun framesForSession(session: TrackerSession): Int {
            val endMs = session.trimEndMs ?: return MAX_PROCESSED_FRAMES

            val spanMs = endMs - session.trimStartMs
            if (spanMs <= 0) return 2

            // +1 because a span of N frame-intervals contains N+1 frame boundaries.
            val frames = ceil(spanMs / 1000.0 * session.fps).toInt() + 1
            return frames.coerceIn(2, MAX_PROCESSED_FRAMES)
        }
    }
}
