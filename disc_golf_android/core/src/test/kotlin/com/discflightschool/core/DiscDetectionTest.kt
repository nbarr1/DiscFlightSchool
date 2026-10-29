package com.discflightschool.core

import com.discflightschool.core.detection.DiscDetection
import com.discflightschool.core.detection.FlightTrackingResult
import com.discflightschool.core.detection.FrameSampling
import com.discflightschool.core.detection.Trajectory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class DiscDetectionTest {

    private fun detection(
        frame: Int,
        x: Double,
        y: Double,
        confidence: Double = 0.9,
        size: Double = 0.03,
    ) = DiscDetection(
        frameIndex = frame,
        x = x,
        y = y,
        width = size,
        height = size,
        confidence = confidence,
        timestampMs = frame * 100L,
    )

    // ── selectClosestCandidate ───────────────────────────────────────────

    @Test
    fun `picks the candidate nearest the prediction over the more confident one`() {
        val near = detection(5, 0.51, 0.51, confidence = 0.3)
        val far = detection(5, 0.9, 0.9, confidence = 0.95)

        // A distant high-confidence blob should lose to the one consistent with
        // the track.
        assertSame(near, Trajectory.selectClosestCandidate(listOf(far, near), 0.5, 0.5))
    }

    @Test
    fun `breaks a close tie toward the more confident candidate`() {
        val lessConfident = detection(5, 0.50, 0.50, confidence = 0.2)
        val moreConfident = detection(5, 0.505, 0.505, confidence = 0.9)

        assertSame(
            moreConfident,
            Trajectory.selectClosestCandidate(listOf(lessConfident, moreConfident), 0.5, 0.5),
        )
    }

    @Test
    fun `returns the sole candidate unchanged`() {
        val only = detection(5, 0.2, 0.8, confidence = 0.5)
        assertSame(only, Trajectory.selectClosestCandidate(listOf(only), 0.9, 0.1))
    }

    // ── spatial coherence filter ─────────────────────────────────────────

    @Test
    fun `keeps a smooth trajectory intact`() {
        val path = (0 until 10).map { detection(it, 0.1 + it * 0.05, 0.5) }
        assertEquals(10, Trajectory.filterSpatialCoherence(path, 10).size)
    }

    @Test
    fun `rejects scattered noise in favour of the coherent chain`() {
        val path = (0 until 8).map { detection(it, 0.1 + it * 0.04, 0.5) }
        // Outliers occupy frames the smooth path does not, so the filter has to
        // choose between them rather than the two colliding on one frame key.
        val noisy = path + listOf(detection(8, 0.95, 0.05), detection(9, 0.02, 0.98))

        val result = Trajectory.filterSpatialCoherence(noisy, 10)

        for (d in result) {
            assertEquals("kept an outlier at frame ${d.frameIndex}", 0.5, d.y, 1e-9)
        }
        assertEquals(8, result.size)
    }

    @Test
    fun `passes through fewer than three detections unchanged`() {
        val input = listOf(detection(0, 0.1, 0.1), detection(1, 0.9, 0.9))
        assertEquals(2, Trajectory.filterSpatialCoherence(input, 2).size)
    }

    @Test
    fun `returns detections in frame order`() {
        val shuffled = listOf(
            detection(5, 0.3, 0.5),
            detection(0, 0.1, 0.5),
            detection(3, 0.22, 0.5),
            detection(1, 0.14, 0.5),
        )
        val frames = Trajectory.filterSpatialCoherence(shuffled, 6).map { it.frameIndex }
        assertEquals(frames.sorted(), frames)
    }

    @Test
    fun `coherence filter handles an empty input`() {
        assertTrue(Trajectory.filterSpatialCoherence(emptyList(), 0).isEmpty())
    }

    // ── smoothing ────────────────────────────────────────────────────────

    @Test
    fun `averages positions across the window`() {
        val noisy = listOf(
            detection(0, 0.0, 0.5),
            detection(1, 1.0, 0.5),
            detection(2, 0.0, 0.5),
            detection(3, 1.0, 0.5),
            detection(4, 0.0, 0.5),
        )
        val smoothed = Trajectory.smoothDetections(noisy, windowSize = 3)

        assertEquals(5, smoothed.size)
        // The interior points pull toward the mean rather than staying at the
        // alternating extremes.
        assertTrue(smoothed[2].x > 0.0)
        assertTrue(smoothed[2].x < 1.0)
    }

    @Test
    fun `smoothing preserves frame indices and confidence`() {
        val input = listOf(
            detection(4, 0.1, 0.1, confidence = 0.7),
            detection(5, 0.2, 0.2, confidence = 0.8),
            detection(6, 0.3, 0.3, confidence = 0.9),
        )
        val smoothed = Trajectory.smoothDetections(input, windowSize = 3)
        assertEquals(listOf(4, 5, 6), smoothed.map { it.frameIndex })
        assertEquals(0.8, smoothed[1].confidence, 0.0)
    }

    @Test
    fun `smoothing returns input unchanged when shorter than the window`() {
        val input = listOf(detection(0, 0.1, 0.1), detection(1, 0.2, 0.2))
        assertEquals(2, Trajectory.smoothDetections(input, windowSize = 5).size)
    }

    @Test
    fun `smoothing leaves a constant track unchanged`() {
        val flat = (0 until 6).map { detection(it, 0.4, 0.6) }
        for (d in Trajectory.smoothDetections(flat, windowSize = 3)) {
            assertEquals(0.4, d.x, 1e-9)
            assertEquals(0.6, d.y, 1e-9)
        }
    }

    // ── gap interpolation ────────────────────────────────────────────────

    @Test
    fun `fills a short gap linearly and marks it interpolated`() {
        val sparse = listOf(detection(0, 0.0, 0.0), detection(4, 0.4, 0.8))
        val filled = Trajectory.interpolateDetections(sparse, fps = 10.0)

        assertEquals(listOf(0, 1, 2, 3, 4), filled.map { it.frameIndex })
        val mid = filled.first { it.frameIndex == 2 }
        assertEquals(0.2, mid.x, 1e-9)
        assertEquals(0.4, mid.y, 1e-9)
        // Interpolated points are flagged with negative confidence.
        assertTrue(mid.confidence < 0)
    }

    @Test
    fun `keeps real detections at full confidence`() {
        val sparse = listOf(detection(0, 0.0, 0.0), detection(3, 0.3, 0.3))
        val filled = Trajectory.interpolateDetections(sparse, fps = 10.0)
        assertTrue(filled.first().confidence >= 0)
        assertTrue(filled.last().confidence >= 0)
    }

    @Test
    fun `does not bridge a gap larger than ten frames`() {
        val sparse = listOf(detection(0, 0.0, 0.0), detection(30, 0.9, 0.9))
        assertEquals(2, Trajectory.interpolateDetections(sparse, fps = 10.0).size)
    }

    @Test
    fun `interpolation passes through fewer than two detections`() {
        assertEquals(
            1,
            Trajectory.interpolateDetections(listOf(detection(0, 0.1, 0.1)), fps = 10.0).size,
        )
        assertTrue(Trajectory.interpolateDetections(emptyList(), fps = 10.0).isEmpty())
    }

    @Test
    fun `assigns timestamps consistent with the frame index and fps`() {
        val sparse = listOf(detection(0, 0.0, 0.0), detection(2, 0.2, 0.2))
        val filled = Trajectory.interpolateDetections(sparse, fps = 20.0)
        assertEquals(50L, filled.first { it.frameIndex == 1 }.timestampMs)
    }

    // ── search window ────────────────────────────────────────────────────

    @Test
    fun `the search window widens with the gap but stays inside its bounds`() {
        val oneFrame = Trajectory.searchWindowSizeFor(1)
        val fiveFrames = Trajectory.searchWindowSizeFor(5)

        assertTrue(fiveFrames >= oneFrame)
        assertTrue(oneFrame >= Trajectory.MIN_TRACKING_WINDOW_SIZE)
        assertTrue(fiveFrames <= Trajectory.MAX_TRACKING_WINDOW_SIZE)
        // A gap beyond the occlusion budget cannot widen the window further.
        assertEquals(
            Trajectory.searchWindowSizeFor(Trajectory.MAX_OCCLUSION_FRAMES + 1),
            Trajectory.searchWindowSizeFor(99),
            0.0,
        )
    }

    // ── FlightTrackingResult ─────────────────────────────────────────────

    @Test
    fun `flight tracking result queries by frame`() {
        val result = FlightTrackingResult(
            detections = listOf(
                detection(0, 0.1, 0.5),
                detection(1, 0.2, 0.5),
                detection(2, 0.3, 0.5),
            ),
            videoWidth = 640.0,
            videoHeight = 1138.0,
            fps = 10.0,
            totalFrames = 3,
        )

        assertEquals(0.2, result.detectionAtFrame(1)!!.x, 1e-9)
        assertNull(result.detectionAtFrame(99))
        assertEquals(2, result.trail(1).size)
        assertEquals(3, result.trail(99).size)
        assertTrue(result.trail(-1).isEmpty())
    }

    // ── frame sampling ───────────────────────────────────────────────────

    @Test
    fun `sampling starts at the trim start, not the start of the file`() {
        val timestamps = FrameSampling.sampleTimestamps(
            fps = 10.0,
            maxFrames = 300,
            startMs = 1500,
            endMs = 2000,
        )

        assertEquals(1500L, timestamps.first())
        assertEquals(listOf(1500L, 1600L, 1700L, 1800L, 1900L, 2000L), timestamps)
    }

    @Test
    fun `sampling covers the trimmed span, not the whole cap`() {
        // A six-second trim at 10fps is 61 frame boundaries.
        val timestamps = FrameSampling.sampleTimestamps(
            fps = 10.0,
            maxFrames = 300,
            startMs = 2000,
            endMs = 8000,
        )
        assertEquals(61, timestamps.size)
        assertEquals(8000L, timestamps.last())
    }

    @Test
    fun `sampling honours the frame cap`() {
        val timestamps = FrameSampling.sampleTimestamps(
            fps = 10.0,
            maxFrames = 5,
            startMs = 0,
            endMs = 60_000,
        )
        assertEquals(5, timestamps.size)
    }

    @Test
    fun `sampling stops at the clip duration when there is no trim end`() {
        val timestamps = FrameSampling.sampleTimestamps(
            fps = 10.0,
            maxFrames = 300,
            startMs = 0,
            endMs = null,
            durationMs = 500,
        )
        assertEquals(6, timestamps.size)
    }

    @Test
    fun `an inverted span samples nothing`() {
        assertTrue(
            FrameSampling.sampleTimestamps(
                fps = 10.0,
                maxFrames = 300,
                startMs = 5000,
                endMs = 1000,
            ).isEmpty(),
        )
    }
}
