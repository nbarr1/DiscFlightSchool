package com.discflightschool.core

import com.discflightschool.core.detection.DiscDetection
import com.discflightschool.core.detection.FlightTrackingResult
import com.discflightschool.core.detection.FrameSampling
import com.discflightschool.core.detection.Trajectory
import com.discflightschool.core.detection.YoloOutput
import com.discflightschool.core.detection.YoloPreprocessor
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

    // ── normalizeModelValue ──────────────────────────────────────────────

    @Test
    fun `passes through already-normalized coordinates`() {
        assertEquals(0.42, YoloOutput.normalizeModelValue(0.42, 640), 1e-9)
    }

    @Test
    fun `divides pixel-space coordinates by the input size`() {
        assertEquals(0.5, YoloOutput.normalizeModelValue(320.0, 640), 1e-9)
    }

    @Test
    fun `clamps model values into zero to one`() {
        assertEquals(0.0, YoloOutput.normalizeModelValue(-5.0, 640), 0.0)
        assertEquals(1.0, YoloOutput.normalizeModelValue(9999.0, 640), 0.0)
    }

    // ── parseBestDetection ───────────────────────────────────────────────

    @Test
    fun `reads the transposed 1x5xN layout`() {
        // Channel-major: cx, cy, w, h, conf — two candidates.
        val output = floatArrayOf(
            0.25f, 0.75f, // cx
            0.35f, 0.85f, // cy
            0.03f, 0.04f, // w
            0.03f, 0.04f, // h
            0.20f, 0.90f, // conf
        )
        val best = YoloOutput.parseBestDetection(
            output = output,
            shape = intArrayOf(1, 5, 2),
            frameIndex = 7,
            fps = 10.0,
            confidenceThreshold = 0.1,
        )

        requireNotNull(best)
        assertEquals(7, best.frameIndex)
        assertEquals(0.75, best.x, 1e-6)
        assertEquals(0.85, best.y, 1e-6)
        assertEquals(0.90, best.confidence, 1e-6)
    }

    @Test
    fun `reads the standard 1xNx5 layout`() {
        val output = floatArrayOf(
            0.25f, 0.35f, 0.03f, 0.03f, 0.20f,
            0.75f, 0.85f, 0.04f, 0.04f, 0.90f,
        )
        val best = YoloOutput.parseBestDetection(
            output = output,
            shape = intArrayOf(1, 2, 5),
            frameIndex = 3,
            fps = 10.0,
            confidenceThreshold = 0.1,
        )

        requireNotNull(best)
        assertEquals(0.75, best.x, 1e-6)
        assertEquals(0.90, best.confidence, 1e-6)
    }

    @Test
    fun `returns null when every candidate is below threshold`() {
        val output = floatArrayOf(0.5f, 0.5f, 0.03f, 0.03f, 0.001f)
        assertNull(
            YoloOutput.parseBestDetection(
                output = output,
                shape = intArrayOf(1, 5, 1),
                frameIndex = 0,
                fps = 10.0,
                confidenceThreshold = 0.1,
            ),
        )
    }

    @Test
    fun `derives the timestamp from frame index and fps`() {
        val output = floatArrayOf(0.5f, 0.5f, 0.03f, 0.03f, 0.99f)
        val best = YoloOutput.parseBestDetection(
            output = output,
            shape = intArrayOf(1, 5, 1),
            frameIndex = 20,
            fps = 10.0,
            confidenceThreshold = 0.1,
        )
        assertEquals(2000L, best!!.timestampMs)
    }

    @Test
    fun `normalizes pixel-space model output`() {
        // Pixel-space coordinates in the model's 640x640 input.
        val best = YoloOutput.parseBestDetection(
            output = floatArrayOf(320f, 192f, 128f, 64f, 0.9f),
            shape = intArrayOf(1, 1, 5),
            frameIndex = 3,
            fps = 10.0,
            confidenceThreshold = 0.1,
        )

        requireNotNull(best)
        assertEquals(0.5, best.x, 0.0001)
        assertEquals(0.3, best.y, 0.0001)
        assertEquals(0.2, best.width, 0.0001)
        assertEquals(0.1, best.height, 0.0001)
    }

    @Test
    fun `candidate parsing sorts by confidence and caps the list`() {
        val output = floatArrayOf(
            0.10f, 0.20f, 0.30f, // cx
            0.10f, 0.20f, 0.30f, // cy
            0.03f, 0.03f, 0.03f, // w
            0.03f, 0.03f, 0.03f, // h
            0.40f, 0.90f, 0.60f, // conf
        )
        val candidates = YoloOutput.parseCandidateDetections(
            output = output,
            shape = intArrayOf(1, 5, 3),
            frameIndex = 1,
            fps = 10.0,
            confidenceThreshold = 0.1,
            maxCandidates = 2,
        )

        assertEquals(2, candidates.size)
        assertEquals(0.90, candidates[0].confidence, 1e-6)
        assertEquals(0.60, candidates[1].confidence, 1e-6)
    }

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

    // ── model geometry ───────────────────────────────────────────────────

    @Test
    fun `expectedAnchors matches the Detect head grid at each input size`() {
        // 80²+40²+20² — the geometry of the YOLO11 export the app bundles.
        assertEquals(8400, YoloOutput.expectedAnchors(640))
        // 40²+20²+10² — the previous 320-input export.
        assertEquals(2100, YoloOutput.expectedAnchors(320))
        assertEquals(3549, YoloOutput.expectedAnchors(416))
    }

    @Test
    fun `recognizes NHWC, the legacy onnx2tf export layout`() {
        val layout = YoloOutput.detectInputLayout(intArrayOf(1, 320, 320, 3))
        assertEquals(320, layout.size)
        assertEquals(false, layout.channelsFirst)
        assertTrue(layout.recognized)
    }

    @Test
    fun `recognizes NCHW, the current LiteRT export layout`() {
        val layout = YoloOutput.detectInputLayout(intArrayOf(1, 3, 640, 640))
        assertEquals(640, layout.size)
        assertEquals(true, layout.channelsFirst)
        assertTrue(layout.recognized)
    }

    @Test
    fun `falls back to the historical NHWC guess for an unrecognized shape`() {
        // Neither dimension 1 nor dimension 3 is 3 — a single-channel model, say.
        val layout = YoloOutput.detectInputLayout(intArrayOf(1, 640, 640, 1))
        assertEquals(640, layout.size)
        assertEquals(false, layout.channelsFirst)
        assertEquals(false, layout.recognized)
    }

    @Test
    fun `falls back to the default size for a shape with no usable dimensions`() {
        val layout = YoloOutput.detectInputLayout(intArrayOf(1))
        assertTrue(layout.size > 0)
        assertEquals(false, layout.channelsFirst)
        assertEquals(false, layout.recognized)
    }

    // ── preprocessing layout ─────────────────────────────────────────────

    /** A 2x2 source, so every pixel's exact value survives into the buffer. */
    private fun fourPixels() = intArrayOf(
        YoloPreprocessor.argb(10, 20, 30),
        YoloPreprocessor.argb(40, 50, 60),
        YoloPreprocessor.argb(70, 80, 90),
        YoloPreprocessor.argb(100, 110, 120),
    )

    @Test
    fun `NHWC writes pixel-interleaved`() {
        val buffer = YoloPreprocessor.writeNormalizedInput(
            pixels = fourPixels(),
            inputSize = 2,
            channelsFirst = false,
        )

        val expected = floatArrayOf(
            10f, 20f, 30f, 40f, 50f, 60f, 70f, 80f, 90f, 100f, 110f, 120f,
        ).map { it / 255f }

        for (i in expected.indices) {
            assertEquals(expected[i], buffer[i], 1e-6f)
        }
    }

    @Test
    fun `NCHW writes channel-planar`() {
        val buffer = YoloPreprocessor.writeNormalizedInput(
            pixels = fourPixels(),
            inputSize = 2,
            channelsFirst = true,
        )

        // Red plane, then green, then blue.
        val expected = floatArrayOf(
            10f, 40f, 70f, 100f,
            20f, 50f, 80f, 110f,
            30f, 60f, 90f, 120f,
        ).map { it / 255f }

        for (i in expected.indices) {
            assertEquals(expected[i], buffer[i], 1e-6f)
        }
    }

    @Test
    fun `the two layouts contain the same values in different shapes`() {
        val pixels = fourPixels()
        val nhwc = YoloPreprocessor.writeNormalizedInput(pixels, 2, channelsFirst = false)
        val nchw = YoloPreprocessor.writeNormalizedInput(pixels, 2, channelsFirst = true)

        for (y in 0 until 2) {
            for (x in 0 until 2) {
                for (c in 0 until 3) {
                    val interleaved = nhwc[(y * 2 + x) * 3 + c]
                    val planar = nchw[c * 4 + y * 2 + x]
                    assertEquals(interleaved, planar, 1e-9f)
                }
            }
        }
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
