package com.discflightschool.core

import com.discflightschool.core.detection.DetectionQualityFlag
import com.discflightschool.core.detection.DiscDetection
import com.discflightschool.core.detection.FlightTrackingResult
import com.discflightschool.core.detection.assessDetectionQuality
import com.discflightschool.core.detection.sampleSeedPoints
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DetectionQualityTest {

    /**
     * A detection at [frame]. A negative [confidence] marks an interpolated
     * point, matching the sentinel the detection pipeline writes.
     */
    private fun detection(frame: Int, confidence: Double = 0.9) = DiscDetection(
        frameIndex = frame,
        x = 0.5,
        y = 0.5,
        width = 0.03,
        height = 0.03,
        confidence = confidence,
        timestampMs = frame * 100L,
    )

    private fun result(detections: List<DiscDetection>, totalFrames: Int? = null) =
        FlightTrackingResult(
            detections = detections,
            videoWidth = 1080.0,
            videoHeight = 1920.0,
            fps = 10.0,
            totalFrames = totalFrames ?: detections.size,
        )

    @Test
    fun `a full confident track raises no flags`() {
        val report = assessDetectionQuality(
            result((0 until 20).map { detection(it) }),
            confidenceFloor = 0.1,
        )

        assertTrue(report.flags.isEmpty())
        assertFalse(report.isLow)
        assertEquals(20, report.realDetections)
        assertEquals(1.0, report.coverage, 0.0001)
        assertEquals(0.0, report.interpolatedFraction, 0.0)
        assertEquals(0.9, report.meanConfidence, 0.0001)
    }

    @Test
    fun `flags a handful of detections as too few`() {
        val report = assessDetectionQuality(
            result((0 until 4).map { detection(it) }, totalFrames = 4),
            confidenceFloor = 0.1,
        )
        assertTrue(DetectionQualityFlag.TOO_FEW_DETECTIONS in report.flags)
    }

    @Test
    fun `exactly the minimum real detections is not too few`() {
        val report = assessDetectionQuality(
            result((0 until 5).map { detection(it) }, totalFrames = 5),
            confidenceFloor = 0.1,
        )
        assertFalse(DetectionQualityFlag.TOO_FEW_DETECTIONS in report.flags)
    }

    @Test
    fun `flags a path spanning under half the clip`() {
        // 10 detections at the start of a 40-frame clip gives coverage 0.25.
        val report = assessDetectionQuality(
            result((0 until 10).map { detection(it) }, totalFrames = 40),
            confidenceFloor = 0.1,
        )
        assertEquals(0.25, report.coverage, 0.0001)
        assertTrue(DetectionQualityFlag.LOW_COVERAGE in report.flags)
    }

    @Test
    fun `coverage exactly at the threshold is not flagged`() {
        // Frames 0 through 19 of a 40-frame clip gives coverage of exactly 0.5.
        val report = assessDetectionQuality(
            result((0 until 20).map { detection(it) }, totalFrames = 40),
            confidenceFloor = 0.1,
        )
        assertEquals(0.5, report.coverage, 0.0001)
        assertFalse(DetectionQualityFlag.LOW_COVERAGE in report.flags)
    }

    @Test
    fun `forty percent interpolated is allowed, above it is flagged`() {
        val atThreshold = result(
            (0 until 6).map { detection(it) } +
                (6 until 10).map { detection(it, confidence = -1.0) },
        )
        assertFalse(
            DetectionQualityFlag.MOSTLY_INTERPOLATED in
                assessDetectionQuality(atThreshold, confidenceFloor = 0.1).flags,
        )

        val overThreshold = result(
            (0 until 5).map { detection(it) } +
                (5 until 10).map { detection(it, confidence = -1.0) },
        )
        assertTrue(
            DetectionQualityFlag.MOSTLY_INTERPOLATED in
                assessDetectionQuality(overThreshold, confidenceFloor = 0.1).flags,
        )
    }

    @Test
    fun `interpolated points are excluded from mean confidence`() {
        val report = assessDetectionQuality(
            result(
                (0 until 8).map { detection(it, confidence = 0.8) } +
                    (8 until 10).map { detection(it, confidence = -1.0) },
            ),
            confidenceFloor = 0.1,
        )
        // 0.8, not the average of 0.8s and -1s.
        assertEquals(0.8, report.meanConfidence, 0.0001)
    }

    @Test
    fun `weak matches are judged against the absolute floor when the user threshold is low`() {
        // 0.02 * 2.5 = 0.05, well under the 0.35 absolute floor, so 0.35 wins
        // and a mean of 0.3 is weak.
        val report = assessDetectionQuality(
            result((0 until 20).map { detection(it, confidence = 0.3) }),
            confidenceFloor = 0.02,
        )
        assertTrue(DetectionQualityFlag.WEAK_MATCHES in report.flags)
    }

    @Test
    fun `weak matches scale with a raised user threshold`() {
        val track = result((0 until 20).map { detection(it, confidence = 0.5) })

        // At a low floor, 0.5 clears the 0.35 bar.
        assertFalse(
            DetectionQualityFlag.WEAK_MATCHES in
                assessDetectionQuality(track, confidenceFloor = 0.1).flags,
        )
        // At floor 0.3 the bar rises to 0.75, so the same track is now weak.
        assertTrue(
            DetectionQualityFlag.WEAK_MATCHES in
                assessDetectionQuality(track, confidenceFloor = 0.3).flags,
        )
    }

    @Test
    fun `an empty result is flagged, but not as a weak match`() {
        val report = assessDetectionQuality(
            result(emptyList(), totalFrames = 20),
            confidenceFloor = 0.1,
        )

        assertTrue(DetectionQualityFlag.TOO_FEW_DETECTIONS in report.flags)
        assertTrue(DetectionQualityFlag.LOW_COVERAGE in report.flags)
        // Nothing was detected, so "the matches were weak" would be misleading.
        assertFalse(DetectionQualityFlag.WEAK_MATCHES in report.flags)
        assertEquals(0.0, report.meanConfidence, 0.0)
    }

    @Test
    fun `an all-interpolated result reports no real detections`() {
        val report = assessDetectionQuality(
            result((0 until 10).map { detection(it, confidence = -1.0) }),
            confidenceFloor = 0.1,
        )

        assertEquals(0, report.realDetections)
        assertEquals(1.0, report.interpolatedFraction, 0.0001)
        assertTrue(DetectionQualityFlag.MOSTLY_INTERPOLATED in report.flags)
        assertTrue(DetectionQualityFlag.TOO_FEW_DETECTIONS in report.flags)
    }

    @Test
    fun `expectedFrames overrides the result-reported span`() {
        val report = assessDetectionQuality(
            result((0 until 20).map { detection(it) }, totalFrames = 20),
            confidenceFloor = 0.1,
            expectedFrames = 100,
        )

        assertEquals(0.2, report.coverage, 0.0001)
        assertTrue(DetectionQualityFlag.LOW_COVERAGE in report.flags)
    }

    @Test
    fun `primaryFlag leads with the most fundamental problem`() {
        val report = assessDetectionQuality(
            result(emptyList(), totalFrames = 20),
            confidenceFloor = 0.1,
        )
        assertEquals(DetectionQualityFlag.TOO_FEW_DETECTIONS, report.primaryFlag)
    }

    // ── sampleSeedPoints ─────────────────────────────────────────────────

    @Test
    fun `samples down to the target, keeping both endpoints`() {
        val sampled = sampleSeedPoints((0 until 100).map { detection(it) }, target = 8)

        assertEquals(8, sampled.size)
        assertEquals(0, sampled.first().frameIndex)
        assertEquals(99, sampled.last().frameIndex)
    }

    @Test
    fun `returns strictly increasing frame indices with no duplicates`() {
        val sampled = sampleSeedPoints((0 until 100).map { detection(it) }, target = 8)

        for (i in 1 until sampled.size) {
            assertTrue(sampled[i].frameIndex > sampled[i - 1].frameIndex)
        }
    }

    @Test
    fun `never selects an interpolated point`() {
        // Only frames 0, 1 and 98, 99 are real; everything between is fill.
        val detections = listOf(detection(0), detection(1)) +
            (2 until 98).map { detection(it, confidence = -1.0) } +
            listOf(detection(98), detection(99))

        val sampled = sampleSeedPoints(detections, target = 8)

        assertEquals(listOf(0, 1, 98, 99), sampled.map { it.frameIndex })
    }

    @Test
    fun `returns everything when there are fewer points than the target`() {
        val sampled = sampleSeedPoints(
            listOf(detection(0), detection(5), detection(9), detection(12)),
            target = 8,
        )
        assertEquals(listOf(0, 5, 9, 12), sampled.map { it.frameIndex })
    }

    @Test
    fun `handles a two-point input`() {
        assertEquals(2, sampleSeedPoints(listOf(detection(0), detection(9)), target = 8).size)
    }

    @Test
    fun `returns empty when nothing was actually detected`() {
        val sampled = sampleSeedPoints((0 until 10).map { detection(it, confidence = -1.0) })
        assertTrue(sampled.isEmpty())
    }

    @Test
    fun `sorts unordered input before sampling`() {
        val sampled = sampleSeedPoints(
            listOf(detection(9), detection(0), detection(5)),
            target = 8,
        )
        assertEquals(listOf(0, 5, 9), sampled.map { it.frameIndex })
    }
}
