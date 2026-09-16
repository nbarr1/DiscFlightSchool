package com.discflightschool.core

import com.discflightschool.core.detection.DiscDetection
import com.discflightschool.core.geometry.Vec2
import com.discflightschool.core.tracking.SimilarityTransform
import com.discflightschool.core.tracking.WorldAnchorFrame
import com.discflightschool.core.tracking.WorldLock
import kotlin.math.PI
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WorldAnchorTest {

    private fun detection(frame: Int, x: Double, y: Double) = DiscDetection(
        frameIndex = frame,
        x = x,
        y = y,
        width = 0.03,
        height = 0.03,
        confidence = 0.9,
        timestampMs = frame * 100L,
    )

    @Test
    fun `an unmoved pair produces the identity transform`() {
        val transform = SimilarityTransform.fromTwoPointPairs(
            Vec2(0.2, 0.2),
            Vec2(0.8, 0.2),
            Vec2(0.2, 0.2),
            Vec2(0.8, 0.2),
        )

        assertEquals(1.0, transform.scale, 1e-9)
        assertEquals(0.0, transform.rotation, 1e-9)
        assertEquals(0.0, transform.translation.x, 1e-9)
        assertEquals(0.0, transform.translation.y, 1e-9)
    }

    @Test
    fun `a panned camera reads as pure translation`() {
        val transform = SimilarityTransform.fromTwoPointPairs(
            Vec2(0.2, 0.2),
            Vec2(0.8, 0.2),
            Vec2(0.3, 0.25),
            Vec2(0.9, 0.25),
        )

        assertEquals(1.0, transform.scale, 1e-9)
        assertEquals(0.0, transform.rotation, 1e-9)
        assertEquals(0.1, transform.translation.x, 1e-9)
        assertEquals(0.05, transform.translation.y, 1e-9)
    }

    @Test
    fun `a zoom reads as scale`() {
        val transform = SimilarityTransform.fromTwoPointPairs(
            Vec2(0.4, 0.5),
            Vec2(0.6, 0.5),
            Vec2(0.3, 0.5),
            Vec2(0.7, 0.5),
        )
        assertEquals(2.0, transform.scale, 1e-9)
    }

    @Test
    fun `a rotated camera reads as rotation`() {
        val transform = SimilarityTransform.fromTwoPointPairs(
            Vec2(0.4, 0.5),
            Vec2(0.6, 0.5),
            Vec2(0.5, 0.4),
            Vec2(0.5, 0.6),
        )
        // The reference segment turned a quarter turn.
        assertEquals(PI / 2, transform.rotation, 1e-9)
    }

    @Test
    fun `apply and inverse round-trip a point`() {
        val transform = SimilarityTransform.fromTwoPointPairs(
            Vec2(0.2, 0.2),
            Vec2(0.8, 0.3),
            Vec2(0.25, 0.4),
            Vec2(0.7, 0.6),
        )
        val point = Vec2(0.42, 0.37)

        val projected = transform.apply(point, 1.0, 1.0)
        val restored = transform.inverse(projected)

        assertEquals(point.x, restored.x, 1e-9)
        assertEquals(point.y, restored.y, 1e-9)
    }

    @Test
    fun `fewer than two anchors leaves positions untouched`() {
        val anchors = listOf(
            WorldAnchorFrame(0, Vec2(0.1, 0.1), Vec2(0.2, 0.1)),
        )
        val position = WorldLock.toCanvas(
            detection = detection(5, 0.5, 0.25),
            currentFrame = 10,
            width = 1000.0,
            height = 500.0,
            anchors = anchors,
        )

        assertEquals(500.0, position.x, 1e-9)
        assertEquals(125.0, position.y, 1e-9)
    }

    @Test
    fun `a panning camera keeps a trail point pinned to the scene`() {
        // The camera pans right by 0.1 between frame 0 and frame 10; a point
        // recorded at frame 0 should be drawn 0.1 further left once the view
        // has moved on.
        val anchors = listOf(
            WorldAnchorFrame(0, Vec2(0.2, 0.5), Vec2(0.4, 0.5)),
            WorldAnchorFrame(10, Vec2(0.3, 0.5), Vec2(0.5, 0.5)),
        )

        val atOwnFrame = WorldLock.toCanvas(
            detection = detection(0, 0.5, 0.5),
            currentFrame = 0,
            width = 1.0,
            height = 1.0,
            anchors = anchors,
        )
        val atLaterFrame = WorldLock.toCanvas(
            detection = detection(0, 0.5, 0.5),
            currentFrame = 10,
            width = 1.0,
            height = 1.0,
            anchors = anchors,
        )

        assertEquals(0.5, atOwnFrame.x, 1e-9)
        assertEquals(0.6, atLaterFrame.x, 1e-9)
        assertEquals(0.5, atLaterFrame.y, 1e-9)
    }

    @Test
    fun `the transform interpolates between surrounding anchors`() {
        val anchors = listOf(
            WorldAnchorFrame(0, Vec2(0.2, 0.5), Vec2(0.4, 0.5)),
            WorldAnchorFrame(10, Vec2(0.4, 0.5), Vec2(0.6, 0.5)),
        )

        val halfway = WorldLock.transformAt(5, anchors)

        assertEquals(0.1, halfway.translation.x, 1e-9)
        assertEquals(1.0, halfway.scale, 1e-9)
    }

    @Test
    fun `frames before the first anchor use the identity`() {
        val anchors = listOf(
            WorldAnchorFrame(4, Vec2(0.2, 0.5), Vec2(0.4, 0.5)),
            WorldAnchorFrame(10, Vec2(0.4, 0.5), Vec2(0.6, 0.5)),
        )

        assertEquals(SimilarityTransform.IDENTITY, WorldLock.transformAt(0, anchors))
    }

    @Test
    fun `a degenerate anchor pair falls back to the identity`() {
        val transform = SimilarityTransform.fromTwoPointPairs(
            Vec2(0.5, 0.5),
            Vec2(0.5, 0.5),
            Vec2(0.2, 0.2),
            Vec2(0.8, 0.8),
        )
        assertTrue(abs(transform.scale - 1.0) < 1e-9)
        assertEquals(SimilarityTransform.IDENTITY, transform)
    }
}
