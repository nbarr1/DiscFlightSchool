package com.discflightschool.core.posture

import com.discflightschool.core.model.FormFrame
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

/** The confidence below which an ML Kit landmark is not trusted for an angle. */
const val LANDMARK_CONFIDENCE_THRESHOLD = 0.5

/**
 * The joint-angle maths that does not need a pose detector: physiological
 * limits, smoothing, phase averaging, and scoring against pro data.
 */
object PostureMath {

    /** Physiological range of motion per angle, in degrees. */
    private val romLimits: Map<String, ClosedFloatingPointRange<Double>> = mapOf(
        "rightElbowAngle" to 40.0..180.0,
        "leftElbowAngle" to 40.0..180.0,
        "rightShoulderAngle" to 0.0..180.0,
        "leftShoulderAngle" to 0.0..180.0,
        "rightKneeAngle" to 30.0..180.0,
        "leftKneeAngle" to 30.0..180.0,
        "spineAngle" to 40.0..90.0,
    )

    /** How far outside its range an angle may sit and still be clamped in. */
    const val ROM_TOLERANCE = 10.0

    /**
     * Clamp angles into physiological range, *dropping* any that sit further
     * than [ROM_TOLERANCE] outside it.
     *
     * Dropping rather than clamping is deliberate: a knee angle of 15 degrees is
     * not a tight knee, it is a bad landmark, and carrying it forward as a
     * clamped 30 would silently corrupt the score. Downstream code must treat a
     * missing key as "not measured".
     */
    fun clampToPhysiologicalLimits(angles: Map<String, Double>): MutableMap<String, Double> {
        val result = LinkedHashMap<String, Double>()
        for ((key, value) in angles) {
            val limits = romLimits[key]
            if (limits == null) {
                result[key] = value
                continue
            }
            val clamped = value.coerceIn(limits)
            if (abs(value - clamped) <= ROM_TOLERANCE) {
                result[key] = clamped
            }
        }
        return result
    }

    /**
     * Swap left and right in angle names, for a left-handed thrower measured
     * against a right-handed pro baseline.
     */
    fun mirrorAngles(angles: Map<String, Double>): MutableMap<String, Double> {
        val result = LinkedHashMap<String, Double>()
        for ((key, value) in angles) {
            val mirrored = when {
                key.startsWith("right") -> "left" + key.substring(5)
                key.startsWith("left") -> "right" + key.substring(4)
                else -> key
            }
            result[mirrored] = value
        }
        return result
    }

    /**
     * Smooth each angle track across [frames] in place: a median filter to
     * reject single-frame landmark glitches, then two moving-average passes.
     *
     * Frames where an angle was never measured stay unmeasured — the filters
     * skip NaN rather than inventing a value for a frame the detector had
     * nothing to say about.
     */
    fun smoothFrameAngles(frames: List<FormFrame>) {
        if (frames.size < 3) return
        val angleNames = frames.flatMap { it.angles.keys }.toSet()
        for (name in angleNames) {
            var data = frames.map { it.angles[name] ?: Double.NaN }
            data = sparseMedianFilter(data, 3)
            data = sparseMovingAverage(data, 9)
            data = sparseMovingAverage(data, 7)
            for (i in frames.indices) {
                if (!data[i].isNaN()) {
                    frames[i].angles[name] = data[i]
                }
            }
        }
    }

    /** Smooth landmark positions across [frames] in place. */
    fun smoothKeyPoints(frames: List<FormFrame>) {
        if (frames.size < 3) return
        val pointNames = frames.flatMap { it.keyPoints.keys }.toSet()
        for (name in pointNames) {
            val xData = frames.map { it.keyPoints[name]?.x ?: Double.NaN }
            val yData = frames.map { it.keyPoints[name]?.y ?: Double.NaN }
            val smoothedX = sparseMovingAverage(xData, 5)
            val smoothedY = sparseMovingAverage(yData, 5)
            for (i in frames.indices) {
                if (frames[i].keyPoints.containsKey(name) && !smoothedX[i].isNaN()) {
                    frames[i].keyPoints[name] =
                        com.discflightschool.core.geometry.Vec2(smoothedX[i], smoothedY[i])
                }
            }
        }
    }

    /** A median filter that ignores NaN holes rather than propagating them. */
    fun sparseMedianFilter(data: List<Double>, window: Int): List<Double> {
        val half = window / 2
        return List(data.size) { i ->
            val start = (i - half).coerceIn(0, data.size - 1)
            val end = (i + half).coerceIn(0, data.size - 1)
            val segment = data.subList(start, end + 1).filterNot { it.isNaN() }.sorted()
            if (segment.isEmpty()) Double.NaN else segment[segment.size / 2]
        }
    }

    /** A moving average that ignores NaN holes rather than propagating them. */
    fun sparseMovingAverage(data: List<Double>, window: Int): List<Double> {
        val half = window / 2
        return List(data.size) { i ->
            val start = (i - half).coerceIn(0, data.size - 1)
            val end = (i + half).coerceIn(0, data.size - 1)
            var sum = 0.0
            var count = 0
            for (j in start..end) {
                if (!data[j].isNaN()) {
                    sum += data[j]
                    count++
                }
            }
            if (count > 0) sum / count else Double.NaN
        }
    }

    /**
     * A 0-100 deviation score against measured pro phase snapshots.
     *
     * [phaseAngles] maps phase name to `{app angle name -> degrees}`.
     * [phaseFrameIndices] maps phase name to the frame index in [frames] where
     * that phase occurs; when provided, each frame snaps to its nearest
     * *measured* phase rather than to the hardcoded 0/0.33/0.67/1.0 fractions.
     * Pass null to fall back to the (less accurate) fractional approximation.
     */
    fun computeProDeviationScore(
        frames: List<FormFrame>,
        phaseAngles: Map<String, Map<String, Double>>,
        throwType: String,
        phaseFrameIndices: Map<String, Int>? = null,
    ): Double {
        if (frames.isEmpty() || phaseAngles.isEmpty()) return 0.0

        val phaseOrder = com.discflightschool.core.baseline.ProBaselineDatabase.phaseNames(throwType)
        val total = frames.size

        val anchors: List<Pair<Int, String>> =
            if (!phaseFrameIndices.isNullOrEmpty()) {
                phaseOrder.filter { phaseFrameIndices.containsKey(it) }
                    .map { phaseFrameIndices.getValue(it) to it }
                    .sortedBy { it.first }
            } else {
                val phaseT = listOf(0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0)
                phaseOrder.mapIndexed { i, phase ->
                    (phaseT[i] * (total - 1)).roundToInt().coerceIn(0, total - 1) to phase
                }
            }

        if (anchors.isEmpty()) return 0.0

        var totalScore = 0.0
        var count = 0

        for (i in 0 until total) {
            // Snap to the nearest anchor.
            var nearest = anchors.first()
            var minDist = abs(i - nearest.first)
            for (anchor in anchors.drop(1)) {
                val d = abs(i - anchor.first)
                if (d < minDist) {
                    minDist = d
                    nearest = anchor
                }
            }

            val proAngles = phaseAngles[nearest.second] ?: continue

            for ((key, value) in frames[i].angles) {
                val proAngle = proAngles[key] ?: continue
                val diff = abs(value - proAngle)
                totalScore += (100 - diff * 2.0).coerceIn(0.0, 100.0)
                count++
            }
        }

        return if (count > 0) totalScore / count else 0.0
    }

    /**
     * Average user angles at each throw phase.
     *
     * With [phaseFrameIndices], each phase averages a ±2 frame window around
     * the measured frame; without it, phases are spaced evenly through the clip.
     */
    fun extractUserPhaseAngles(
        frames: List<FormFrame>,
        throwType: String,
        phaseFrameIndices: Map<String, Int>?,
    ): Map<String, Map<String, Double>> {
        val phaseOrder = com.discflightschool.core.baseline.ProBaselineDatabase.phaseNames(throwType)
        val total = frames.size
        if (total == 0) return emptyMap()
        val result = LinkedHashMap<String, Map<String, Double>>()

        fun windowAround(centerFrame: Int): List<FormFrame> {
            val startF = (centerFrame - 2).coerceIn(0, total - 1)
            val endF = (centerFrame + 2).coerceIn(0, total - 1)
            return frames.subList(startF, endF + 1)
        }

        if (!phaseFrameIndices.isNullOrEmpty()) {
            for (phaseName in phaseOrder) {
                val centerFrame = phaseFrameIndices[phaseName] ?: continue
                result[phaseName] = averageAngles(windowAround(centerFrame))
            }
        } else {
            val phaseT = listOf(0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0)
            for (i in phaseOrder.indices) {
                val frameIdx = (phaseT[i] * (total - 1)).roundToInt().coerceIn(0, total - 1)
                result[phaseOrder[i]] = averageAngles(windowAround(frameIdx))
            }
        }
        return result
    }

    /** The mean of each angle present across [frames]. */
    fun averageAngles(frames: List<FormFrame>): Map<String, Double> {
        if (frames.isEmpty()) return emptyMap()
        val sums = LinkedHashMap<String, Double>()
        val counts = LinkedHashMap<String, Int>()
        for (frame in frames) {
            for ((key, value) in frame.angles) {
                sums[key] = (sums[key] ?: 0.0) + value
                counts[key] = (counts[key] ?: 0) + 1
            }
        }
        return sums.mapValues { (key, sum) -> sum / counts.getValue(key) }
    }

    /**
     * Reverse-look up the JSON angle key from an app angle key.
     *
     * Pure, and shared with the suggestion text, so a label can never disagree
     * with the data the suggestion was computed from.
     */
    fun reverseAngleKey(appKey: String, throwType: String): String? =
        com.discflightschool.core.baseline.ProBaselineDatabase.reverseMapping(throwType)[appKey]

    /**
     * Whether an app knee-angle key refers to the lead or the trail leg for a
     * given throw type, or null when [appKey] is not a knee angle.
     *
     * Derived from the same mapping the pro baseline data is selected with. For
     * a forehand the right knee is the *trail* leg; a hardcoded `right == lead`
     * would mislabel every FH tip.
     */
    fun kneeSideLabel(appKey: String, throwType: String): String? =
        when (reverseAngleKey(appKey, throwType)) {
            "lead_knee_flexion_deg" -> "lead"
            "trail_knee_flexion_deg" -> "trail"
            else -> null
        }

    /** Synthesized angles used only when analysis could not run. */
    fun mockAngles(progress: Double): MutableMap<String, Double> = mutableMapOf(
        "rightElbowAngle" to 140 - sin(progress * Math.PI) * 50,
        "leftElbowAngle" to 140 + sin(progress * Math.PI) * 20,
        "rightShoulderAngle" to 90 + cos(progress * Math.PI * 2) * 60,
        "leftShoulderAngle" to 100 + sin(progress * Math.PI) * 30,
        "rightKneeAngle" to 160 + sin(progress * Math.PI * 2) * 20,
        "leftKneeAngle" to 160 - sin(progress * Math.PI * 2) * 15,
        "spineAngle" to 85 + sin(progress * Math.PI) * 10,
    )
}
