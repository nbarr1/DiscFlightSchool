package com.discflightschool.core

import com.discflightschool.core.detection.DetectionCancelledException
import com.discflightschool.core.tracking.CloudDiscTracker
import com.discflightschool.core.tracking.CloudTrack
import com.discflightschool.core.tracking.CloudTrackPoint
import com.discflightschool.core.tracking.CloudTrackSource
import com.discflightschool.core.tracking.TrackerSession
import java.io.IOException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class CloudDiscTrackerTest {

    private val session = TrackerSession(
        videoPath = "/clips/throw.mp4",
        fps = 10.0,
        totalFrames = 21,
        videoWidth = 1080.0,
        videoHeight = 1920.0,
        trimStartMs = 1_500,
        trimEndMs = 3_500,
    )

    private fun point(frame: Int, timeMs: Long, x: Double, confidence: Double = 0.8) =
        CloudTrackPoint(frame, timeMs, x = x, y = 0.5, width = 0.04, height = 0.07, confidence = confidence)

    /** A disc moving steadily right over 2 seconds, at the 30 fps the server reports. */
    private fun straightFlight(): CloudTrack = CloudTrack(
        fps = 30.0,
        frameCount = 61,
        points = (0..60).map { frame ->
            point(frame, timeMs = Math.round(frame * 1000.0 / 30.0), x = 0.2 + frame * 0.005)
        },
    )

    // ── parsing ──────────────────────────────────────────────────────────

    @Test
    fun `parses the server's track`() {
        // Shaped like the endpoint's live output.
        val track = CloudTrack.parse(
            """
            {"fps": 30.0, "frameCount": 61, "detections": [
              {"frame": 0, "timeMs": 0, "x": 0.22578, "y": 0.47222, "width": 0.04531,
               "height": 0.07222, "confidence": 0.78666},
              {"frame": 1, "timeMs": 33, "x": 0.23359, "y": 0.45833, "width": 0.04219,
               "height": 0.07222, "confidence": 0.59744}
            ]}
            """,
        )

        assertEquals(30.0, track.fps, 0.0)
        assertEquals(61, track.frameCount)
        assertEquals(
            CloudTrackPoint(1, 33, 0.23359, 0.45833, 0.04219, 0.07222, 0.59744),
            track.points[1],
        )
    }

    @Test
    fun `skips a malformed point instead of failing the track`() {
        val track = CloudTrack.parse(
            """
            {"fps": 30, "frameCount": 4, "detections": [
              {"frame": 0, "timeMs": 0, "x": 0.5, "y": 0.5, "width": 0.1, "height": 0.1, "confidence": 0.9},
              {"frame": 1, "timeMs": 33, "x": 1.5, "y": 0.5, "width": 0.1, "height": 0.1, "confidence": 0.9},
              {"frame": 2, "timeMs": 67, "x": "0.5", "y": 0.5, "width": 0.1, "height": 0.1, "confidence": 0.9},
              {"frame": 3, "timeMs": 100, "y": 0.5, "width": 0.1, "height": 0.1, "confidence": 0.9},
              "not a point"
            ]}
            """,
        )

        assertEquals(listOf(0), track.points.map { it.frame })
    }

    @Test
    fun `a point without a time gets one from its frame`() {
        val track = CloudTrack.parse(
            """{"fps": 30, "detections": [{"frame": 3, "x": 0.5, "y": 0.5, "width": 0.1, "height": 0.1, "confidence": 0.9}]}""",
        )

        assertEquals(100L, track.points.single().timeMs)
    }

    @Test
    fun `rejects a body that is not a track`() {
        for (body in listOf("", "[]", """{"detections": []}""", """{"fps": 30}""", """{"fps": 0, "detections": []}""")) {
            assertThrows(body, IllegalArgumentException::class.java) { CloudTrack.parse(body) }
        }
    }

    // ── mapping onto the session ─────────────────────────────────────────

    @Test
    fun `maps the server's frames onto the session's frames`() {
        val result = CloudDiscTracker.toFlightResult(straightFlight(), session)

        assertEquals((0..20).toList(), result.detections.map { it.frameIndex })
        assertEquals((0..20).map { it * 100L }, result.detections.map { it.timestampMs })
        // Session frame 10 is 1,000 ms in, which is server frame 30. Smoothing
        // leaves a straight line's interior points where they were.
        assertEquals(0.2 + 30 * 0.005, result.detections[10].x, 1e-9)
        assertTrue(result.detections.all { it.isReal })
        assertEquals(1080.0, result.videoWidth, 0.0)
        assertEquals(1920.0, result.videoHeight, 0.0)
        assertEquals(10.0, result.fps, 0.0)
        assertEquals(21, result.totalFrames)
    }

    @Test
    fun `the point nearest a session frame's time wins over a more confident one`() {
        val track = CloudTrack(
            fps = 30.0,
            frameCount = 4,
            points = listOf(
                point(0, 0, x = 0.1),
                // Both round to session frame 1 (100 ms).
                point(1, 90, x = 0.9, confidence = 0.99),
                point(2, 100, x = 0.15, confidence = 0.5),
            ),
        )

        val result = CloudDiscTracker.toFlightResult(track, session)

        assertEquals(listOf(0, 1), result.detections.map { it.frameIndex })
        assertEquals(0.15, result.detections[1].x, 0.0)
    }

    @Test
    fun `drops points past the end of the session`() {
        val shortSession = session.copy(totalFrames = 11)

        val result = CloudDiscTracker.toFlightResult(straightFlight(), shortSession)

        assertEquals((0..10).toList(), result.detections.map { it.frameIndex })
    }

    @Test
    fun `fills short gaps the way the on-device pipeline does`() {
        val track = CloudTrack(
            fps = 30.0,
            frameCount = 61,
            points = straightFlight().points.filterNot { it.timeMs in 350L..650L },
        )

        val result = CloudDiscTracker.toFlightResult(track, session)

        assertEquals((0..20).toList(), result.detections.map { it.frameIndex })
        assertEquals(listOf(4, 5, 6), result.detections.filterNot { it.isReal }.map { it.frameIndex })
    }

    // ── running a fetch ──────────────────────────────────────────────────

    private class RecordingSource(private val track: CloudTrack) : CloudTrackSource {
        var request: Triple<String, Long, Long?>? = null

        override suspend fun fetchTrack(
            videoPath: String,
            startMs: Long,
            endMs: Long?,
            onProgress: (Double?, String) -> Unit,
        ): CloudTrack {
            request = Triple(videoPath, startMs, endMs)
            onProgress(0.5, "Detecting disc: frame 30 of 61")
            return track
        }
    }

    @Test
    fun `asks the source for the session's trimmed range and reports its progress`() = runBlocking {
        val source = RecordingSource(straightFlight())
        val reported = mutableListOf<Pair<Double?, String>>()
        val tracker = CloudDiscTracker(source) { fraction, status -> reported += fraction to status }

        val result = tracker.track(session, emptyList())

        assertEquals(Triple("/clips/throw.mp4", 1_500L, 3_500L), source.request)
        assertEquals(listOf<Pair<Double?, String>>(0.5 to "Detecting disc: frame 30 of 61"), reported)
        assertEquals(1.0, tracker.progress, 0.0)
        assertEquals(21, result.detections.size)
    }

    @Test
    fun `a source failure reaches the caller unchanged`() {
        val tracker = CloudDiscTracker(
            object : CloudTrackSource {
                override suspend fun fetchTrack(
                    videoPath: String,
                    startMs: Long,
                    endMs: Long?,
                    onProgress: (Double?, String) -> Unit,
                ): CloudTrack = throw IOException("Invalid or missing API key")
            },
        )

        val error = assertThrows(IOException::class.java) {
            runBlocking { tracker.track(session, emptyList()) }
        }
        assertEquals("Invalid or missing API key", error.message)
    }

    @Test
    fun `cancel stops the fetch and reports a cancellation`() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val fetchCancelled = CompletableDeferred<Unit>()
        val tracker = CloudDiscTracker(
            object : CloudTrackSource {
                override suspend fun fetchTrack(
                    videoPath: String,
                    startMs: Long,
                    endMs: Long?,
                    onProgress: (Double?, String) -> Unit,
                ): CloudTrack {
                    started.complete(Unit)
                    try {
                        awaitCancellation()
                    } finally {
                        fetchCancelled.complete(Unit)
                    }
                }
            },
        )

        val run = async { runCatching { tracker.track(session, emptyList()) } }
        started.await()
        tracker.cancel()

        assertTrue(run.await().exceptionOrNull() is DetectionCancelledException)
        assertTrue(fetchCancelled.isCompleted)
    }
}
