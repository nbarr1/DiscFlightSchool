package com.discflightschool.core.tracking

import com.discflightschool.core.detection.DetectorModelUnavailableException
import com.discflightschool.core.detection.DiscDetection
import com.discflightschool.core.detection.FlightTrackingResult
import com.discflightschool.core.detection.Trajectory
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.roundToInt

/** One decoded frame's model output: every disc box above the model's threshold. */
data class FrameDetections(
    /** Frames from the trim start, at the rate passed to [WorkflowFrameDetector.detectFrames]. */
    val frame: Int,
    val timeMs: Long,
    val frameWidth: Int,
    val frameHeight: Int,
    val detections: List<TrackerDetection>,
)

/** Runs the disc model over a clip. The app implements it with RF-DETR on ONNX Runtime. */
interface WorkflowFrameDetector {
    val progress: Double
    val statusMessage: String

    /** Load the model, throwing if it cannot be loaded at all. */
    suspend fun loadModel()

    /**
     * Decode [startMs] to [endMs] (null for the end of the file) of [videoPath]
     * at [fps], at most [maxFrames] frames, and hand each frame's detections
     * to [onFrame] in order.
     *
     * @throws com.discflightschool.core.detection.DetectionCancelledException when cancelled.
     */
    suspend fun detectFrames(
        videoPath: String,
        fps: Double,
        maxFrames: Int,
        startMs: Long,
        endMs: Long?,
        onFrame: (FrameDetections) -> Unit,
    )
}

/**
 * The steps of the Roboflow Workflow `disc-golf-flight-tracker` after its
 * model, for one clip: keep the `disc` class, track it with OC-SORT
 * (`tracked_disc`), and take each frame's disc as the server did: the most
 * confident tracked box, or the most confident detection when the tracker
 * kept none.
 */
class DiscFlightWorkflow(fps: Double, settings: OcSortSettings = OcSortSettings()) {
    private val tracker = OcSortTracker(fps, settings)

    /** The disc in this frame, normalized to it, or null when the model found none. */
    fun next(frame: FrameDetections): DiscBox? {
        val tracked = tracker.update(frame.detections).map { frame.detections[it.detectionIndex] }
        val best = tracked.maxByOrNull { it.confidence } ?: frame.detections.maxByOrNull { it.confidence }
        return best?.let { DiscBox.of(it, frame.frameWidth, frame.frameHeight) }
    }
}

/** A disc box as fractions of the frame; `x`/`y` is its center. */
data class DiscBox(val x: Double, val y: Double, val width: Double, val height: Double, val confidence: Double) {
    companion object {
        fun of(detection: TrackerDetection, frameWidth: Int, frameHeight: Int): DiscBox {
            val box = detection.box
            return DiscBox(
                x = (box.centerX / frameWidth).coerceIn(0.0, 1.0),
                y = (box.centerY / frameHeight).coerceIn(0.0, 1.0),
                width = ((box.x2 - box.x1) / frameWidth).coerceIn(0.0, 1.0),
                height = ((box.y2 - box.y1) / frameHeight).coerceIn(0.0, 1.0),
                confidence = detection.confidence,
            )
        }
    }
}

/**
 * The automatic tracker: the Roboflow Workflow's disc model and tracker,
 * run on the phone.
 *
 * The Workflow tracks at the video's own frame rate, and OC-SORT's motion
 * model is tuned per frame, so this runs it at [WORKFLOW_FPS] rather than at
 * the session's coarser rate, then maps the positions onto the session's
 * frames and cleans them up as the other automatic trackers do.
 */
class WorkflowDiscTracker(private val detector: WorkflowFrameDetector) : DiscTracker {

    override val progress: Double get() = detector.progress

    override val statusMessage: String get() = detector.statusMessage

    override suspend fun track(
        session: TrackerSession,
        // Ignored: this tracker finds the disc itself. Callers pass an empty list.
        seedPoints: List<TrackerSeedPoint>,
    ): FlightTrackingResult {
        try {
            detector.loadModel()
        } catch (e: Throwable) {
            throw DetectorModelUnavailableException(e)
        }
        val workflow = DiscFlightWorkflow(WORKFLOW_FPS)
        val points = ArrayList<Pair<Long, DiscBox>>()
        detector.detectFrames(
            videoPath = session.videoPath,
            fps = WORKFLOW_FPS,
            maxFrames = framesFor(session),
            startMs = session.trimStartMs,
            endMs = session.trimEndMs,
        ) { frame ->
            workflow.next(frame)?.let { points += frame.timeMs to it }
        }
        return toFlightResult(points, session)
    }

    /** Nothing to release: the detector is app-scoped. */
    override fun dispose() = Unit

    companion object {
        /** The rate the Workflow runs at: the frame rate of most phone video. */
        const val WORKFLOW_FPS = 30.0

        /** The `confidence` the outer Workflow passes to its model step. */
        const val CONFIDENCE_THRESHOLD = 0.15

        /** At most ten seconds of video in one run. */
        const val MAX_PROCESSED_FRAMES = 300

        fun framesFor(session: TrackerSession): Int {
            val endMs = session.trimEndMs ?: return MAX_PROCESSED_FRAMES
            val spanMs = endMs - session.trimStartMs
            if (spanMs <= 0) return 2
            return (ceil(spanMs / 1000.0 * WORKFLOW_FPS).toInt() + 1).coerceIn(2, MAX_PROCESSED_FRAMES)
        }

        /**
         * Map [points] (time from the trim start, box) onto [session]'s frames
         * and clean them up as the on-device pipeline does.
         *
         * Several Workflow frames fall on each session frame. The one nearest
         * the session frame's time wins, and the higher confidence breaks a tie.
         */
        fun toFlightResult(points: List<Pair<Long, DiscBox>>, session: TrackerSession): FlightTrackingResult {
            val nearest = HashMap<Int, Pair<Long, DiscBox>>()
            for (point in points) {
                val (timeMs, box) = point
                val frame = (timeMs * session.fps / 1000.0).roundToInt()
                if (frame !in 0 until session.totalFrames) continue
                val current = nearest[frame]
                if (current == null) {
                    nearest[frame] = point
                    continue
                }
                val target = FrameIndexing.timestampOf(frame, session.fps)
                val offset = abs(timeMs - target)
                val currentOffset = abs(current.first - target)
                if (offset < currentOffset || (offset == currentOffset && box.confidence > current.second.confidence)) {
                    nearest[frame] = point
                }
            }
            val raw = nearest.entries
                .sortedBy { it.key }
                .map { (frame, point) ->
                    val box = point.second
                    DiscDetection(
                        frameIndex = frame,
                        x = box.x,
                        y = box.y,
                        width = box.width,
                        height = box.height,
                        confidence = box.confidence,
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
