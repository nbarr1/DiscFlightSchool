package com.discflightschool.core.detection

import com.discflightschool.core.geometry.Vec2
import kotlin.math.roundToLong

/**
 * One extracted video frame, tagged with the frame index it was sampled at.
 *
 * The index is carried explicitly rather than implied by list position:
 * extraction can skip a frame mid-video, and using list position would then
 * shift every later frame's timestamp and spline anchor relative to the actual
 * video.
 */
data class ExtractedFrame(val index: Int, val path: String)

/** A detected disc position in a single frame. */
data class DiscDetection(
    val frameIndex: Int,
    /** Center x, normalized 0-1. */
    val x: Double,
    /** Center y, normalized 0-1. */
    val y: Double,
    /** Box width, normalized 0-1. */
    val width: Double,
    /** Box height, normalized 0-1. */
    val height: Double,
    /** Model confidence, or -1 for a point invented by gap interpolation. */
    val confidence: Double,
    val timestampMs: Long,
) {
    val center: Vec2 get() = Vec2(x, y)

    /** True when this point came from the model rather than from interpolation. */
    val isReal: Boolean get() = confidence >= 0

    companion object {
        fun timestampFor(frameIndex: Int, fps: Double): Long =
            (frameIndex * 1000.0 / fps).roundToLong()
    }
}

/** The result of tracking a full video — disc positions per frame. */
data class FlightTrackingResult(
    val detections: List<DiscDetection>,
    val videoWidth: Double,
    val videoHeight: Double,
    val fps: Double,
    val totalFrames: Int,
) {
    /** The disc position at a given frame, or null if it was never detected there. */
    fun detectionAtFrame(frame: Int): DiscDetection? =
        detections.firstOrNull { it.frameIndex == frame }

    /** Every detection up to and including [frame]. */
    fun detectionsUpToFrame(frame: Int): List<DiscDetection> =
        detections.filter { it.frameIndex <= frame }

    /** Trail points up to the current frame. */
    fun trail(currentFrame: Int): List<Vec2> =
        detectionsUpToFrame(currentFrame).map { Vec2(it.x, it.y) }
}

/**
 * Thrown when a detection run was stopped by the user rather than failing on
 * its own. Callers should treat this as "the user changed their mind" and stay
 * quiet, not surface it as an error.
 */
class DetectionCancelledException : Exception("Disc detection was cancelled")

/**
 * Thrown when the detector model could not be loaded at all, so automatic
 * detection cannot run. Kept distinct from "ran, and found nothing" so the UI
 * can tell the user which of the two actually happened.
 */
class DetectorModelUnavailableException(cause: Throwable) :
    Exception("Disc detector model unavailable: $cause", cause)
