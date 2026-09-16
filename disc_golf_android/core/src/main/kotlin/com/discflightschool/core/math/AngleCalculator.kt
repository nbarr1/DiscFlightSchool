package com.discflightschool.core.math

import com.discflightschool.core.geometry.Vec2
import com.discflightschool.core.geometry.Vec3
import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.atan2
import kotlin.math.sqrt

/**
 * Shared utility for angle calculations and Catmull-Rom spline interpolation.
 *
 * Used by posture analysis, pose correction, and hybrid disc detection, so the
 * three cannot drift apart in how they measure a joint or bridge a gap.
 */
object AngleCalculator {

    private const val RAD_TO_DEG = 180.0 / Math.PI

    // ---------------------------------------------------------------------
    // 2-D helpers
    // ---------------------------------------------------------------------

    /** The angle in degrees at vertex [b], formed by points [a]-[b]-[c]. */
    fun angleBetween(a: Vec2, b: Vec2, c: Vec2): Double {
        val ba = a - b
        val bc = c - b

        val dot = ba.x * bc.x + ba.y * bc.y
        val magBA = ba.distance
        val magBC = bc.distance

        if (magBA == 0.0 || magBC == 0.0) return 0.0

        val cosAngle = dot / (magBA * magBC)
        return acos(cosAngle.coerceIn(-1.0, 1.0)) * RAD_TO_DEG
    }

    /**
     * All seven app angles from a key-point map.
     *
     * Keys are in the format `PoseLandmarkType.rightShoulder`, matching what
     * the pose analyzer writes and what persisted sessions already contain.
     */
    fun calculateFromKeyPoints(keyPoints: Map<String, Vec2>): MutableMap<String, Double> {
        val angles = mutableMapOf<String, Double>()

        fun kp(name: String): Vec2? = keyPoints["PoseLandmarkType.$name"]

        val rightShoulder = kp("rightShoulder")
        val rightElbow = kp("rightElbow")
        val rightWrist = kp("rightWrist")
        val rightHip = kp("rightHip")
        val leftShoulder = kp("leftShoulder")
        val leftElbow = kp("leftElbow")
        val leftWrist = kp("leftWrist")
        val leftHip = kp("leftHip")
        val rightKnee = kp("rightKnee")
        val rightAnkle = kp("rightAnkle")
        val leftKnee = kp("leftKnee")
        val leftAnkle = kp("leftAnkle")

        if (rightShoulder != null && rightElbow != null && rightWrist != null) {
            angles["rightElbowAngle"] = angleBetween(rightShoulder, rightElbow, rightWrist)
        }
        if (leftShoulder != null && leftElbow != null && leftWrist != null) {
            angles["leftElbowAngle"] = angleBetween(leftShoulder, leftElbow, leftWrist)
        }
        if (rightElbow != null && rightShoulder != null && rightHip != null) {
            angles["rightShoulderAngle"] = angleBetween(rightElbow, rightShoulder, rightHip)
        }
        if (leftElbow != null && leftShoulder != null && leftHip != null) {
            angles["leftShoulderAngle"] = angleBetween(leftElbow, leftShoulder, leftHip)
        }
        if (rightHip != null && rightKnee != null && rightAnkle != null) {
            angles["rightKneeAngle"] = angleBetween(rightHip, rightKnee, rightAnkle)
        }
        if (leftHip != null && leftKnee != null && leftAnkle != null) {
            angles["leftKneeAngle"] = angleBetween(leftHip, leftKnee, leftAnkle)
        }

        // Spine angle — uses midpoints of shoulders and hips.
        if (rightShoulder != null && leftShoulder != null && rightHip != null && leftHip != null) {
            val shoulderMidX = (rightShoulder.x + leftShoulder.x) / 2
            val shoulderMidY = (rightShoulder.y + leftShoulder.y) / 2
            val hipMidX = (rightHip.x + leftHip.x) / 2
            val hipMidY = (rightHip.y + leftHip.y) / 2

            val spineAngle = atan2(
                shoulderMidX - hipMidX,
                hipMidY - shoulderMidY, // y-down in image coords
            ) * RAD_TO_DEG
            angles["spineAngle"] = 90 - abs(spineAngle)
        }

        return angles
    }

    // ---------------------------------------------------------------------
    // 3-D helpers
    // ---------------------------------------------------------------------

    private fun sub(a: Vec3, b: Vec3) = Vec3(a.x - b.x, a.y - b.y, a.z - b.z)

    private fun dot(a: Vec3, b: Vec3) = a.x * b.x + a.y * b.y + a.z * b.z

    private fun mag(v: Vec3) = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)

    private fun cross(a: Vec3, b: Vec3) = Vec3(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x,
    )

    /**
     * The angle in degrees at vertex [b] using 3-D coordinates.
     * Returns [Double.NaN] if either vector has zero magnitude.
     */
    fun angleBetween3D(a: Vec3, b: Vec3, c: Vec3): Double {
        val ba = sub(a, b)
        val bc = sub(c, b)
        val magBA = mag(ba)
        val magBC = mag(bc)
        if (magBA == 0.0 || magBC == 0.0) return Double.NaN
        val cosAngle = dot(ba, bc) / (magBA * magBC)
        return acos(cosAngle.coerceIn(-1.0, 1.0)) * RAD_TO_DEG
    }

    /**
     * The X-factor: the signed angle between the shoulder plane and the hip
     * plane, projected onto the horizontal plane.
     *
     * A positive value means the shoulders have rotated further than the hips —
     * the key mechanical advantage in disc golf and golf.
     *
     * Returns [Double.NaN] if depth data is degenerate.
     */
    fun xFactor3D(
        rightShoulder: Vec3,
        leftShoulder: Vec3,
        rightHip: Vec3,
        leftHip: Vec3,
    ): Double {
        val shoulderAxis = sub(rightShoulder, leftShoulder)
        val hipAxis = sub(rightHip, leftHip)

        if (mag(shoulderAxis) == 0.0 || mag(hipAxis) == 0.0) return Double.NaN

        // Project both axes onto the horizontal plane (ignore the y component).
        val sFlat = Vec3(shoulderAxis.x, 0.0, shoulderAxis.z)
        val hFlat = Vec3(hipAxis.x, 0.0, hipAxis.z)
        val magSF = mag(sFlat)
        val magHF = mag(hFlat)
        if (magSF == 0.0 || magHF == 0.0) return Double.NaN

        val cosAngle = dot(sFlat, hFlat) / (magSF * magHF)
        val angle = acos(cosAngle.coerceIn(-1.0, 1.0)) * RAD_TO_DEG

        // Sign comes from the cross product's Y component.
        return if (cross(sFlat, hFlat).y >= 0) angle else -angle
    }

    // ---------------------------------------------------------------------
    // Catmull-Rom spline interpolation
    // ---------------------------------------------------------------------

    /** Catmull-Rom spline interpolation for a single scalar value. */
    fun catmullRom(p0: Double, p1: Double, p2: Double, p3: Double, t: Double): Double {
        val t2 = t * t
        val t3 = t2 * t
        return 0.5 * (
            (2 * p1) +
                (-p0 + p2) * t +
                (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
                (-p0 + 3 * p1 - 3 * p2 + p3) * t3
            )
    }

    /** Catmull-Rom spline interpolation for 2-D points. */
    fun catmullRomVec(p0: Vec2, p1: Vec2, p2: Vec2, p3: Vec2, t: Double): Vec2 = Vec2(
        catmullRom(p0.x, p1.x, p2.x, p3.x, t),
        catmullRom(p0.y, p1.y, p2.y, p3.y, t),
    )

    /**
     * Interpolate positions between anchor frames using Catmull-Rom splines.
     *
     * [anchorFrames] maps frame index to position. Returns interpolated
     * positions for every frame between the first and last anchor.
     */
    fun interpolateAnchors(anchorFrames: Map<Int, Vec2>): Map<Int, Vec2> {
        if (anchorFrames.isEmpty()) return emptyMap()

        val sortedKeys = anchorFrames.keys.sorted()
        val result = LinkedHashMap<Int, Vec2>()

        for (key in sortedKeys) {
            result[key] = anchorFrames.getValue(key)
        }

        for (i in 0 until sortedKeys.size - 1) {
            val f1 = sortedKeys[i]
            val f2 = sortedKeys[i + 1]
            val span = f2 - f1
            if (span <= 1) continue

            val p0 = if (i > 0) anchorFrames.getValue(sortedKeys[i - 1]) else anchorFrames.getValue(f1)
            val p1 = anchorFrames.getValue(f1)
            val p2 = anchorFrames.getValue(f2)
            val p3 = if (i < sortedKeys.size - 2) {
                anchorFrames.getValue(sortedKeys[i + 2])
            } else {
                anchorFrames.getValue(f2)
            }

            for (f in 1 until span) {
                val t = f.toDouble() / span
                result[f1 + f] = catmullRomVec(p0, p1, p2, p3, t)
            }
        }

        return result
    }
}
