package com.discflightschool.core

import com.discflightschool.core.tracking.FrameIndexing
import com.discflightschool.core.tracking.GeometricSplineTracker
import com.discflightschool.core.tracking.TrackerSeedPoint
import com.discflightschool.core.tracking.TrackerSession
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class TrackerTest {

    private fun session(
        trimStartMs: Long = 0,
        trimEndMs: Long? = null,
        fps: Double = 10.0,
    ) = TrackerSession(
        videoPath = "/fake/path.mp4",
        fps = fps,
        totalFrames = 60,
        videoWidth = 1080.0,
        videoHeight = 1920.0,
        trimStartMs = trimStartMs,
        trimEndMs = trimEndMs,
    )

    // ── GeometricSplineTracker ───────────────────────────────────────────

    @Test
    fun `interpolates a straight horizontal line between two seed points`() = runBlocking {
        val tracker = GeometricSplineTracker()
        val result = tracker.track(
            session = session().copy(totalFrames = 11),
            seedPoints = listOf(
                TrackerSeedPoint(frameIndex = 0, x = 0.1, y = 0.5),
                TrackerSeedPoint(frameIndex = 10, x = 0.9, y = 0.5),
            ),
        )

        assertEquals(11, result.detections.size)
        assertEquals(0.1, result.detections.first().x, 0.0001)
        assertEquals(0.9, result.detections.last().x, 0.0001)

        // The midpoint of a straight two-point line should land at the midpoint.
        val mid = result.detections.first { it.frameIndex == 5 }
        assertEquals(0.5, mid.x, 0.0001)
        assertEquals(0.5, mid.y, 0.0001)

        // Endpoints are seed points, so full confidence; interior points are not.
        assertEquals(1.0, result.detections.first().confidence, 0.0)
        assertEquals(0.5, mid.confidence, 0.0)
    }

    @Test
    fun `spline tracker rejects fewer than two seed points`() {
        val tracker = GeometricSplineTracker()
        assertThrows(IllegalArgumentException::class.java) {
            runBlocking {
                tracker.track(
                    session = session().copy(totalFrames = 5),
                    seedPoints = listOf(TrackerSeedPoint(frameIndex = 0, x = 0.1, y = 0.5)),
                )
            }
        }
    }

    // ── FrameIndexing ────────────────────────────────────────────────────

    @Test
    fun `frame 0 is the trim start, not the start of the file`() {
        assertEquals(0, FrameIndexing.frameIndexAt(2000, 2000, 10.0))
        assertEquals(10, FrameIndexing.frameIndexAt(3000, 2000, 10.0))
    }

    @Test
    fun `round-trips a position back to itself`() {
        for (trimStartMs in listOf(0L, 1500L, 12345L)) {
            for (offsetMs in listOf(0L, 100L, 900L, 5000L)) {
                val frame = FrameIndexing.frameIndexAt(trimStartMs + offsetMs, trimStartMs, 10.0)
                assertEquals(offsetMs, FrameIndexing.timestampOf(frame, 10.0))
            }
        }
    }

    @Test
    fun `TrackerSession delegates to the same maths`() {
        val session = session(trimStartMs = 2000, trimEndMs = 8000)

        assertEquals(10, session.frameIndexAt(3000))
        assertEquals(1000L, session.timestampOf(10))
    }

    @Test
    fun `tracker progress and status are reported through the detector`() = runBlocking {
        val tracker = GeometricSplineTracker()
        tracker.track(
            session = session().copy(totalFrames = 11),
            seedPoints = listOf(
                TrackerSeedPoint(0, 0.1, 0.5),
                TrackerSeedPoint(10, 0.9, 0.5),
            ),
        )
        assertEquals(1.0, tracker.progress, 0.0)
        assertTrue(tracker.statusMessage.isNotEmpty())
    }
}
