package com.discflightschool.core

import com.discflightschool.core.geometry.Vec2
import com.discflightschool.core.geometry.Vec3
import com.discflightschool.core.math.AngleCalculator
import kotlin.math.abs
import kotlin.math.sign
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AngleCalculatorTest {

    private fun keyPoints(raw: Map<String, Vec2>): Map<String, Vec2> =
        raw.mapKeys { (key, _) -> "PoseLandmarkType.$key" }

    // ── angleBetween (2D) ────────────────────────────────────────────────

    @Test
    fun `a right angle measures 90 degrees`() {
        val angle = AngleCalculator.angleBetween(Vec2(0.0, 1.0), Vec2.ZERO, Vec2(1.0, 0.0))
        assertEquals(90.0, angle, 1e-9)
    }

    @Test
    fun `a straight limb measures 180 degrees`() {
        val angle = AngleCalculator.angleBetween(Vec2(-1.0, 0.0), Vec2.ZERO, Vec2(1.0, 0.0))
        assertEquals(180.0, angle, 1e-9)
    }

    @Test
    fun `a fully folded limb measures 0 degrees`() {
        val angle = AngleCalculator.angleBetween(Vec2(1.0, 0.0), Vec2.ZERO, Vec2(2.0, 0.0))
        assertEquals(0.0, angle, 1e-9)
    }

    @Test
    fun `is invariant to translation and uniform scale`() {
        val a = Vec2(0.0, 3.0)
        val b = Vec2(1.0, 1.0)
        val c = Vec2(4.0, 1.0)
        val base = AngleCalculator.angleBetween(a, b, c)

        val shift = Vec2(100.0, -50.0)
        val translated = AngleCalculator.angleBetween(a + shift, b + shift, c + shift)
        val scaled = AngleCalculator.angleBetween(a * 7.0, b * 7.0, c * 7.0)

        assertEquals(base, translated, 1e-9)
        assertEquals(base, scaled, 1e-9)
    }

    @Test
    fun `degenerate input returns 0 rather than NaN`() {
        // 0 is indistinguishable from a genuinely folded limb here. The 3-D
        // variant returns NaN instead.
        val angle = AngleCalculator.angleBetween(Vec2.ZERO, Vec2.ZERO, Vec2(1.0, 0.0))
        assertEquals(0.0, angle, 0.0)
    }

    @Test
    fun `never returns NaN from floating point drift at the extremes`() {
        for (scale in listOf(1e-6, 1.0, 1e6)) {
            val angle = AngleCalculator.angleBetween(
                Vec2(-scale, 0.0),
                Vec2.ZERO,
                Vec2(scale, 0.0),
            )
            assertFalse(angle.isNaN())
            assertEquals(180.0, angle, 1e-6)
        }
    }

    // ── angleBetween3D ───────────────────────────────────────────────────

    @Test
    fun `a 3D right angle measures 90 degrees`() {
        val angle = AngleCalculator.angleBetween3D(
            Vec3(0.0, 1.0, 0.0),
            Vec3(0.0, 0.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
        )
        assertEquals(90.0, angle, 1e-9)
    }

    @Test
    fun `uses depth, not just the projection`() {
        // Identical in x/y, different in z: the 2-D calculation would see a
        // straight line; the 3-D one must not.
        val angle = AngleCalculator.angleBetween3D(
            Vec3(0.0, 0.0, 1.0),
            Vec3(0.0, 0.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
        )
        assertEquals(90.0, angle, 1e-9)
    }

    @Test
    fun `degenerate 3D input returns NaN so callers can drop it`() {
        val angle = AngleCalculator.angleBetween3D(
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 0.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
        )
        assertTrue(angle.isNaN())
    }

    // ── xFactor3D ────────────────────────────────────────────────────────

    @Test
    fun `x factor is zero when shoulders and hips are aligned`() {
        val x = AngleCalculator.xFactor3D(
            Vec3(1.0, 0.0, 0.0),
            Vec3(-1.0, 0.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(-1.0, 0.0, 0.0),
        )
        assertEquals(0.0, x, 1e-9)
    }

    @Test
    fun `x factor measures separation when shoulders rotate past the hips`() {
        val x = AngleCalculator.xFactor3D(
            Vec3(1.0, 0.0, 1.0),
            Vec3(-1.0, 0.0, -1.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(-1.0, 0.0, 0.0),
        )
        assertEquals(45.0, abs(x), 1e-6)
    }

    @Test
    fun `x factor sign flips with rotation direction`() {
        val positive = AngleCalculator.xFactor3D(
            Vec3(1.0, 0.0, 1.0),
            Vec3(-1.0, 0.0, -1.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(-1.0, 0.0, 0.0),
        )
        val negative = AngleCalculator.xFactor3D(
            Vec3(1.0, 0.0, -1.0),
            Vec3(-1.0, 0.0, 1.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(-1.0, 0.0, 0.0),
        )
        assertNotEquals(sign(positive), sign(negative))
        assertEquals(abs(negative), abs(positive), 1e-6)
    }

    @Test
    fun `x factor returns NaN when depth is degenerate`() {
        val x = AngleCalculator.xFactor3D(
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 0.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(-1.0, 0.0, 0.0),
        )
        assertTrue(x.isNaN())
    }

    // ── catmullRom ───────────────────────────────────────────────────────

    @Test
    fun `spline passes exactly through its control points`() {
        assertEquals(10.0, AngleCalculator.catmullRom(0.0, 10.0, 20.0, 30.0, 0.0), 1e-12)
        assertEquals(20.0, AngleCalculator.catmullRom(0.0, 10.0, 20.0, 30.0, 1.0), 1e-12)
    }

    @Test
    fun `spline is linear for evenly spaced collinear points`() {
        for (t in listOf(0.25, 0.5, 0.75)) {
            assertEquals(
                10 + 10 * t,
                AngleCalculator.catmullRom(0.0, 10.0, 20.0, 30.0, t),
                1e-9,
            )
        }
    }

    @Test
    fun `spline stays monotonic through a monotonic control sequence`() {
        var previous = AngleCalculator.catmullRom(0.0, 1.0, 2.0, 3.0, 0.0)
        for (i in 1..20) {
            val value = AngleCalculator.catmullRom(0.0, 1.0, 2.0, 3.0, i / 20.0)
            assertTrue(value >= previous - 1e-12)
            previous = value
        }
    }

    @Test
    fun `catmullRomVec interpolates both axes`() {
        val mid = AngleCalculator.catmullRomVec(
            Vec2(0.0, 0.0),
            Vec2(10.0, 100.0),
            Vec2(20.0, 200.0),
            Vec2(30.0, 300.0),
            0.5,
        )
        assertEquals(15.0, mid.x, 1e-9)
        assertEquals(150.0, mid.y, 1e-9)
    }

    @Test
    fun `catmullRom matches the classic formulation`() {
        fun reference(p0: Double, p1: Double, p2: Double, p3: Double, t: Double): Double {
            val t2 = t * t
            val t3 = t2 * t
            return 0.5 * (
                (2 * p1) +
                    (-p0 + p2) * t +
                    (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
                    (-p0 + 3 * p1 - 3 * p2 + p3) * t3
                )
        }

        val random = Random(20260804)
        repeat(200) {
            val p0 = random.nextDouble()
            val p1 = random.nextDouble()
            val p2 = random.nextDouble()
            val p3 = random.nextDouble()
            val t = random.nextDouble()
            assertEquals(
                reference(p0, p1, p2, p3, t),
                AngleCalculator.catmullRom(p0, p1, p2, p3, t),
                1e-12,
            )
        }
    }

    // ── interpolateAnchors ───────────────────────────────────────────────

    @Test
    fun `interpolateAnchors returns an empty map for empty input`() {
        assertTrue(AngleCalculator.interpolateAnchors(emptyMap()).isEmpty())
    }

    @Test
    fun `interpolateAnchors preserves anchors exactly`() {
        val anchors = mapOf(
            0 to Vec2(0.1, 0.9),
            10 to Vec2(0.5, 0.5),
            20 to Vec2(0.9, 0.1),
        )
        val result = AngleCalculator.interpolateAnchors(anchors)

        for ((frame, point) in anchors) {
            assertEquals(point.x, result.getValue(frame).x, 1e-12)
            assertEquals(point.y, result.getValue(frame).y, 1e-12)
        }
    }

    @Test
    fun `interpolateAnchors fills every frame between the first and last anchor`() {
        val result = AngleCalculator.interpolateAnchors(
            mapOf(0 to Vec2(0.0, 0.0), 5 to Vec2(1.0, 1.0), 10 to Vec2(2.0, 0.0)),
        )
        for (frame in 0..10) {
            assertTrue("missing $frame", result.containsKey(frame))
        }
    }

    @Test
    fun `interpolateAnchors interpolates a straight line linearly in interior segments`() {
        // Only interior segments have four distinct control points. The first
        // and last segments duplicate an endpoint, which is standard
        // Catmull-Rom end handling and is not linear even for collinear
        // anchors — so this asserts on the middle segment.
        val result = AngleCalculator.interpolateAnchors(
            mapOf(
                0 to Vec2(0.0, 0.0),
                4 to Vec2(4.0, 8.0),
                8 to Vec2(8.0, 16.0),
                12 to Vec2(12.0, 24.0),
            ),
        )
        assertEquals(6.0, result.getValue(6).x, 1e-9)
        assertEquals(12.0, result.getValue(6).y, 1e-9)
    }

    @Test
    fun `interpolateAnchors endpoint segments stay within the anchor range`() {
        val result = AngleCalculator.interpolateAnchors(
            mapOf(
                0 to Vec2(0.1, 0.9),
                10 to Vec2(0.5, 0.5),
                20 to Vec2(0.9, 0.1),
            ),
        )
        for (point in result.values) {
            assertTrue(point.x in 0.0..1.0)
            assertTrue(point.y in 0.0..1.0)
        }
    }

    @Test
    fun `interpolateAnchors handles adjacent anchors with no gap to fill`() {
        val result = AngleCalculator.interpolateAnchors(
            mapOf(0 to Vec2(0.0, 0.0), 1 to Vec2(1.0, 1.0)),
        )
        assertEquals(2, result.size)
    }

    @Test
    fun `interpolateAnchors is order independent`() {
        val ascending = AngleCalculator.interpolateAnchors(
            linkedMapOf(0 to Vec2(0.0, 0.0), 5 to Vec2(1.0, 1.0), 10 to Vec2(2.0, 2.0)),
        )
        val shuffled = AngleCalculator.interpolateAnchors(
            linkedMapOf(10 to Vec2(2.0, 2.0), 0 to Vec2(0.0, 0.0), 5 to Vec2(1.0, 1.0)),
        )
        for (frame in ascending.keys) {
            assertEquals(ascending.getValue(frame).x, shuffled.getValue(frame).x, 1e-12)
            assertEquals(ascending.getValue(frame).y, shuffled.getValue(frame).y, 1e-12)
        }
    }

    // ── calculateFromKeyPoints ───────────────────────────────────────────

    @Test
    fun `computes an elbow angle from shoulder elbow wrist`() {
        val angles = AngleCalculator.calculateFromKeyPoints(
            keyPoints(
                mapOf(
                    "rightShoulder" to Vec2(0.0, 0.0),
                    "rightElbow" to Vec2(0.0, 1.0),
                    "rightWrist" to Vec2(1.0, 1.0),
                ),
            ),
        )
        assertEquals(90.0, angles.getValue("rightElbowAngle"), 1e-9)
    }

    @Test
    fun `omits angles whose landmarks are missing`() {
        val angles = AngleCalculator.calculateFromKeyPoints(
            keyPoints(
                mapOf(
                    "rightShoulder" to Vec2(0.0, 0.0),
                    "rightElbow" to Vec2(0.0, 1.0),
                    // no wrist
                ),
            ),
        )
        assertFalse(angles.containsKey("rightElbowAngle"))
    }

    @Test
    fun `reports a vertical spine as 90 degrees`() {
        val angles = AngleCalculator.calculateFromKeyPoints(
            keyPoints(
                mapOf(
                    "rightShoulder" to Vec2(1.0, 0.0),
                    "leftShoulder" to Vec2(-1.0, 0.0),
                    "rightHip" to Vec2(1.0, 2.0),
                    "leftHip" to Vec2(-1.0, 2.0),
                ),
            ),
        )
        assertEquals(90.0, angles.getValue("spineAngle"), 1e-9)
    }

    @Test
    fun `a leaning spine reads below 90 degrees`() {
        val angles = AngleCalculator.calculateFromKeyPoints(
            keyPoints(
                mapOf(
                    "rightShoulder" to Vec2(2.0, 0.0),
                    "leftShoulder" to Vec2(0.0, 0.0),
                    "rightHip" to Vec2(1.0, 2.0),
                    "leftHip" to Vec2(-1.0, 2.0),
                ),
            ),
        )
        assertTrue(angles.getValue("spineAngle") < 90.0)
    }

    @Test
    fun `returns an empty map for empty input`() {
        assertTrue(AngleCalculator.calculateFromKeyPoints(emptyMap()).isEmpty())
    }

    @Test
    fun `produces no NaN values for a plausible full skeleton`() {
        val angles = AngleCalculator.calculateFromKeyPoints(
            keyPoints(
                mapOf(
                    "rightShoulder" to Vec2(0.55, 0.30),
                    "leftShoulder" to Vec2(0.45, 0.30),
                    "rightElbow" to Vec2(0.62, 0.42),
                    "leftElbow" to Vec2(0.38, 0.42),
                    "rightWrist" to Vec2(0.68, 0.55),
                    "leftWrist" to Vec2(0.32, 0.55),
                    "rightHip" to Vec2(0.53, 0.55),
                    "leftHip" to Vec2(0.47, 0.55),
                    "rightKnee" to Vec2(0.54, 0.72),
                    "leftKnee" to Vec2(0.46, 0.72),
                    "rightAnkle" to Vec2(0.55, 0.90),
                    "leftAnkle" to Vec2(0.45, 0.90),
                ),
            ),
        )

        assertTrue(angles.isNotEmpty())
        for ((key, value) in angles) {
            assertFalse("$key is NaN", value.isNaN())
            assertTrue("$key is infinite", value.isFinite())
        }
        for (key in listOf("rightElbowAngle", "leftElbowAngle", "rightKneeAngle")) {
            assertTrue(angles.getValue(key) in 0.0..180.0)
        }
    }
}
