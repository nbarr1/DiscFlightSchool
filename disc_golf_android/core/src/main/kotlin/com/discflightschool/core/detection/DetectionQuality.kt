package com.discflightschool.core.detection

import com.discflightschool.core.tracking.TrackerSeedPoint
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Ways an automatically detected flight path can be untrustworthy.
 *
 * These are warnings, not failures: the path is still shown. They exist so the
 * user is told when a plausible-looking curve is mostly guesswork, rather than
 * being left to discover it by eye.
 */
enum class DetectionQualityFlag {
    /** The disc was only ever located in a handful of frames. */
    TOO_FEW_DETECTIONS,

    /** The path spans well under half the clip — the disc likely left frame. */
    LOW_COVERAGE,

    /** More of the path was filled in between sightings than actually detected. */
    MOSTLY_INTERPOLATED,

    /**
     * The detections that did land were weak relative to the user's own
     * sensitivity setting — often a sign of tracking something that is not the
     * disc.
     */
    WEAK_MATCHES,
}

/** A quality assessment of a [FlightTrackingResult] produced by automatic detection. */
data class DetectionQualityReport(
    /** Detections that came from the model, excluding interpolated fill. */
    val realDetections: Int,
    /** The fraction of the clip the path spans, 0-1. */
    val coverage: Double,
    /** The fraction of the path's points that were interpolated, 0-1. */
    val interpolatedFraction: Double,
    /** Mean confidence across real detections only, or 0 when there are none. */
    val meanConfidence: Double,
    val flags: List<DetectionQualityFlag>,
) {
    val isLow: Boolean get() = flags.isNotEmpty()

    /**
     * The flag to lead with when explaining the problem to the user. Ordered by
     * how fundamental the problem is, not by severity of the number.
     */
    val primaryFlag: DetectionQualityFlag? get() = flags.firstOrNull()
}

/**
 * Thresholds for [assessDetectionQuality].
 *
 * Grouped and named so they can be retuned from device data in one commit
 * without touching the logic that reads them.
 */
object DetectionQualityThresholds {
    /**
     * Below this many model-sourced detections, the path is a lucky guess
     * rather than a track.
     */
    const val MIN_REAL_DETECTIONS = 5

    /**
     * The minimum fraction of the clip the path must span.
     *
     * The coherence filter already treats a chain covering 40% of frames as
     * good enough to stop searching, so anything below half the clip is a
     * fragment by the pipeline's own standard.
     */
    const val MIN_COVERAGE = 0.5

    /**
     * Above this fraction of interpolated points, the user is looking at a
     * drawn line more than a detected one. Gaps of up to 10 frames get bridged
     * during interpolation, so this climbs quickly on a patchy track.
     */
    const val MAX_INTERPOLATED_FRACTION = 0.4

    /**
     * A floor on mean confidence, regardless of how low the user has set their
     * sensitivity.
     */
    const val MIN_MEAN_CONFIDENCE = 0.35

    /**
     * Mean confidence must also clear the user's own threshold by this factor.
     *
     * The threshold is user-tunable from Training Settings, so a fixed bar
     * would fire constantly for anyone who lowered it and never for anyone who
     * raised it.
     */
    const val MEAN_CONFIDENCE_FLOOR_MULTIPLE = 2.5
}

/**
 * Assess how much to trust an automatically detected [result].
 *
 * [confidenceFloor] should be the detector's live confidence threshold, so the
 * weak-match test scales with the user's own sensitivity setting.
 * [expectedFrames] defaults to the result's own frame span.
 */
fun assessDetectionQuality(
    result: FlightTrackingResult,
    confidenceFloor: Double,
    expectedFrames: Int? = null,
): DetectionQualityReport {
    val detections = result.detections

    // Interpolated points are marked with a sentinel confidence of -1 rather
    // than being flagged separately.
    val real = detections.filter { it.isReal }

    val total = detections.size
    val interpolatedFraction =
        if (total == 0) 0.0 else (total - real.size).toDouble() / total

    val meanConfidence =
        if (real.isEmpty()) 0.0 else real.sumOf { it.confidence } / real.size

    val frameBudget = expectedFrames ?: result.totalFrames
    var coverage = 0.0
    if (frameBudget > 0 && detections.isNotEmpty()) {
        val minFrame = detections.minOf { it.frameIndex }
        val maxFrame = detections.maxOf { it.frameIndex }
        coverage = (maxFrame - minFrame + 1).toDouble() / frameBudget
    }

    val flags = ArrayList<DetectionQualityFlag>()

    if (real.size < DetectionQualityThresholds.MIN_REAL_DETECTIONS) {
        flags += DetectionQualityFlag.TOO_FEW_DETECTIONS
    }
    if (coverage < DetectionQualityThresholds.MIN_COVERAGE) {
        flags += DetectionQualityFlag.LOW_COVERAGE
    }
    if (interpolatedFraction > DetectionQualityThresholds.MAX_INTERPOLATED_FRACTION) {
        flags += DetectionQualityFlag.MOSTLY_INTERPOLATED
    }

    val confidenceBar = max(
        DetectionQualityThresholds.MIN_MEAN_CONFIDENCE,
        confidenceFloor * DetectionQualityThresholds.MEAN_CONFIDENCE_FLOOR_MULTIPLE,
    )
    // An empty result is already covered by TOO_FEW_DETECTIONS; flagging it as a
    // weak match too would just stack a second, less useful message on it.
    if (real.isNotEmpty() && meanConfidence < confidenceBar) {
        flags += DetectionQualityFlag.WEAK_MATCHES
    }

    return DetectionQualityReport(
        realDetections = real.size,
        coverage = coverage,
        interpolatedFraction = interpolatedFraction,
        meanConfidence = meanConfidence,
        flags = flags,
    )
}

/**
 * How many editable keyframes to seed from an automatic result by default.
 *
 * Enough control points for a Catmull-Rom spline over a two-to-four second
 * flight, few enough to hand-correct in under a minute, and comfortably above
 * the three that hybrid tracking needs — so Auto-Refine is available
 * immediately after converting.
 */
const val DEFAULT_SEED_POINT_TARGET = 8

/**
 * Sample [detections] down to at most [target] evenly spaced seed points for
 * hand-editing.
 *
 * Interpolated points are never selected. They were invented to bridge gaps,
 * and promoting one to a user-editable keyframe would turn a gap in the data
 * into a fact the user appears to have confirmed.
 */
fun sampleSeedPoints(
    detections: List<DiscDetection>,
    target: Int = DEFAULT_SEED_POINT_TARGET,
): List<TrackerSeedPoint> {
    val real = detections.filter { it.isReal }.sortedBy { it.frameIndex }

    if (real.isEmpty()) return emptyList()
    val wanted = if (target < 2) 2 else target
    if (real.size <= wanted) {
        return real.map { TrackerSeedPoint(it.frameIndex, it.x, it.y) }
    }

    // Even spacing that always lands on both endpoints — the same idiom used
    // elsewhere for picking representative frames out of a sequence.
    val step = (real.size - 1).toDouble() / (wanted - 1)
    val picked = sortedSetOf<Int>()
    for (i in 0 until wanted) {
        picked += (i * step).roundToInt().coerceIn(0, real.size - 1)
    }

    return picked.map { TrackerSeedPoint(real[it].frameIndex, real[it].x, real[it].y) }
}
