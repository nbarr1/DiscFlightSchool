package com.discflightschool.core

import com.discflightschool.core.detection.DetectorModelUnavailableException
import com.discflightschool.core.detection.DiscDetection
import com.discflightschool.core.detection.FlightTrackingResult
import com.discflightschool.core.tracking.AutoDiscTracker
import com.discflightschool.core.tracking.FrameIndexing
import com.discflightschool.core.tracking.GeometricSplineTracker
import com.discflightschool.core.tracking.TrackerSeedPoint
import com.discflightschool.core.tracking.TrackerSession
import com.discflightschool.core.tracking.VideoDiscDetector
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class TrackerTest {

    /**
     * Records what the tracker asked the detector for, so the forwarding can be
     * asserted without TFLite or a real video file.
     */
    private class RecordingDetector(
        private val loadFailure: Throwable? = null,
    ) : VideoDiscDetector {
        var videoPath: String? = null
        var fps: Double? = null
        var maxFrames: Int? = null
        var startMs: Long? = null
        var endMs: Long? = null
        var callCount = 0
        var loadCount = 0

        override val progress: Double = 0.0
        override val statusMessage: String = ""

        var result = FlightTrackingResult(
            detections = listOf(
                DiscDetection(
                    frameIndex = 0,
                    x = 0.1,
                    y = 0.5,
                    width = 0.03,
                    height = 0.03,
                    confidence = 0.9,
                    timestampMs = 0,
                ),
            ),
            // Deliberately unlike anything a caller would pass, so a test can
            // tell whether the tracker re-stated the session's dimensions or
            // passed these straight through.
            videoWidth = 640.0,
            videoHeight = 360.0,
            fps = 10.0,
            totalFrames = 1,
        )

        override suspend fun loadModel() {
            loadCount++
            loadFailure?.let { throw it }
        }

        override suspend fun processVideo(
            videoPath: String,
            fps: Double,
            maxFrames: Int,
            startMs: Long,
            endMs: Long?,
        ): FlightTrackingResult {
            callCount++
            this.videoPath = videoPath
            this.fps = fps
            this.maxFrames = maxFrames
            this.startMs = startMs
            this.endMs = endMs
            return result
        }
    }

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

    // ── AutoDiscTracker.framesForSession ─────────────────────────────────

    @Test
    fun `derives the frame count from the trimmed span`() {
        // A six-second trim at 10fps is 61 frames, not the 300-frame cap.
        assertEquals(
            61,
            AutoDiscTracker.framesForSession(session(trimStartMs = 2000, trimEndMs = 8000)),
        )
    }

    @Test
    fun `falls back to the full cap when there is no trim end`() {
        assertEquals(
            AutoDiscTracker.MAX_PROCESSED_FRAMES,
            AutoDiscTracker.framesForSession(session(trimStartMs = 2000)),
        )
    }

    @Test
    fun `clamps a very long span to the cap`() {
        assertEquals(
            AutoDiscTracker.MAX_PROCESSED_FRAMES,
            AutoDiscTracker.framesForSession(session(trimStartMs = 0, trimEndMs = 600_000)),
        )
    }

    @Test
    fun `returns a usable minimum for a zero or inverted span`() {
        assertEquals(
            2,
            AutoDiscTracker.framesForSession(session(trimStartMs = 5000, trimEndMs = 5000)),
        )
        assertEquals(
            2,
            AutoDiscTracker.framesForSession(session(trimStartMs = 5000, trimEndMs = 1000)),
        )
    }

    // ── AutoDiscTracker.track ────────────────────────────────────────────

    @Test
    fun `accepts an empty seed point list`() = runBlocking {
        val detector = RecordingDetector()
        val result = AutoDiscTracker(detector)
            .track(session(trimEndMs = 6000), emptyList())

        assertEquals(1, detector.callCount)
        assertEquals(1, result.detections.size)
    }

    @Test
    fun `forwards the trim range verbatim`() = runBlocking {
        val detector = RecordingDetector()
        AutoDiscTracker(detector).track(session(trimStartMs = 2500, trimEndMs = 8500), emptyList())

        assertEquals("/fake/path.mp4", detector.videoPath)
        assertEquals(2500L, detector.startMs)
        assertEquals(8500L, detector.endMs)
        assertEquals(10.0, detector.fps!!, 0.0)
    }

    @Test
    fun `passes the derived frame count, not the default cap`() = runBlocking {
        val detector = RecordingDetector()
        AutoDiscTracker(detector).track(session(trimStartMs = 2000, trimEndMs = 8000), emptyList())

        assertEquals(61, detector.maxFrames)
    }

    @Test
    fun `reports the session dimensions rather than the extraction ones`() = runBlocking {
        val detector = RecordingDetector()
        val result = AutoDiscTracker(detector).track(session(trimEndMs = 6000), emptyList())

        // The detector returned 640x360 — the downscaled working resolution.
        assertEquals(1080.0, result.videoWidth, 0.0)
        assertEquals(1920.0, result.videoHeight, 0.0)
    }

    @Test
    fun `wraps a model load failure and never runs detection`() {
        val detector = RecordingDetector(loadFailure = IllegalStateException("no native library"))
        val tracker = AutoDiscTracker(detector)

        assertThrows(DetectorModelUnavailableException::class.java) {
            runBlocking { tracker.track(session(trimEndMs = 6000), emptyList()) }
        }
        assertEquals(0, detector.callCount)
    }

    @Test
    fun `dispose leaves the app-scoped detector usable`() = runBlocking {
        // The detector is app-scoped and shared, so disposing a tracker must not
        // close it. Calling through the tracker again after dispose is the
        // observable proof.
        val detector = RecordingDetector()
        val tracker = AutoDiscTracker(detector)

        tracker.dispose()
        tracker.track(session(trimEndMs = 6000), emptyList())

        assertEquals(1, detector.callCount)
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
