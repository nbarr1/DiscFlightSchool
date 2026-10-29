package com.discflightschool.core

import com.discflightschool.core.detection.DetectorModelUnavailableException
import com.discflightschool.core.tracking.DiscBox
import com.discflightschool.core.tracking.DiscFlightWorkflow
import com.discflightschool.core.tracking.FrameDetections
import com.discflightschool.core.tracking.PixelBox
import com.discflightschool.core.tracking.TrackerDetection
import com.discflightschool.core.tracking.TrackerSession
import com.discflightschool.core.tracking.WorkflowDiscTracker
import com.discflightschool.core.tracking.WorkflowFrameDetector
import java.io.IOException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkflowDiscTrackerTest {

    private val session = TrackerSession(
        videoPath = "/clips/throw.mp4",
        fps = 10.0,
        totalFrames = 21,
        videoWidth = 1080.0,
        videoHeight = 1920.0,
        trimStartMs = 1_500,
        trimEndMs = 3_500,
    )

    private fun box(x: Double, confidence: Double = 0.8) = DiscBox(x, 0.5, 0.04, 0.07, confidence)

    /** A disc moving steadily right over 2 seconds, at the Workflow's 30 fps. */
    private fun straightFlight(): List<Pair<Long, DiscBox>> =
        (0..60).map { frame -> Math.round(frame * 1000.0 / 30.0) to box(0.2 + frame * 0.005) }

    private fun disc(x: Double, confidence: Double = 0.8) =
        TrackerDetection(PixelBox(x, 500.0, x + 20.0, 512.0), confidence)

    private fun frame(index: Int, vararg detections: TrackerDetection) =
        FrameDetections(index, Math.round(index * 1000.0 / 30.0), 1000, 1000, detections.toList())

    // ── the Workflow's per-frame choice ──────────────────────────────────

    @Test
    fun `takes the most confident detection until the tracker keeps one`() {
        val workflow = DiscFlightWorkflow(fps = 30.0)

        // A new track has no id on its first frame, so the raw detections decide.
        val first = workflow.next(frame(0, disc(100.0, 0.5), disc(700.0, 0.9)))!!
        assertEquals(0.71, first.x, 1e-9)
        assertEquals(0.9, first.confidence, 0.0)
        assertEquals(0.02, first.width, 1e-9)
    }

    @Test
    fun `prefers a tracked box over a more confident new one`() {
        val workflow = DiscFlightWorkflow(fps = 30.0)
        workflow.next(frame(0, disc(100.0, 0.5)))
        workflow.next(frame(1, disc(105.0, 0.5)))

        // The disc continues its track; a confident stranger appears far away.
        val chosen = workflow.next(frame(2, disc(110.0, 0.5), disc(800.0, 0.95)))!!

        assertEquals(0.12, chosen.x, 1e-9)
    }

    @Test
    fun `a frame with no detections has no disc`() {
        assertNull(DiscFlightWorkflow(fps = 30.0).next(frame(0)))
    }

    // ── mapping onto the session ─────────────────────────────────────────

    @Test
    fun `maps the Workflow's frames onto the session's frames`() {
        val result = WorkflowDiscTracker.toFlightResult(straightFlight(), session)

        assertEquals((0..20).toList(), result.detections.map { it.frameIndex })
        assertEquals((0..20).map { it * 100L }, result.detections.map { it.timestampMs })
        // Session frame 10 is 1,000 ms in, which is Workflow frame 30. Smoothing
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
        val points = listOf(
            0L to box(0.1),
            // Both round to session frame 1 (100 ms).
            90L to box(0.9, confidence = 0.99),
            100L to box(0.15, confidence = 0.5),
        )

        val result = WorkflowDiscTracker.toFlightResult(points, session)

        assertEquals(listOf(0, 1), result.detections.map { it.frameIndex })
        assertEquals(0.15, result.detections[1].x, 0.0)
    }

    @Test
    fun `drops points past the end of the session`() {
        val result = WorkflowDiscTracker.toFlightResult(straightFlight(), session.copy(totalFrames = 11))

        assertEquals((0..10).toList(), result.detections.map { it.frameIndex })
    }

    @Test
    fun `fills short gaps the way the on-device pipeline does`() {
        val points = straightFlight().filterNot { it.first in 350L..650L }

        val result = WorkflowDiscTracker.toFlightResult(points, session)

        assertEquals((0..20).toList(), result.detections.map { it.frameIndex })
        assertEquals(listOf(4, 5, 6), result.detections.filterNot { it.isReal }.map { it.frameIndex })
    }

    // ── running the detector ─────────────────────────────────────────────

    private open class FakeDetector(private val frames: List<FrameDetections>) : WorkflowFrameDetector {
        var request: List<Any?>? = null
        override val progress = 0.0
        override val statusMessage = ""
        override suspend fun loadModel() = Unit

        override suspend fun detectFrames(
            videoPath: String,
            fps: Double,
            maxFrames: Int,
            startMs: Long,
            endMs: Long?,
            onFrame: (FrameDetections) -> Unit,
        ) {
            request = listOf(videoPath, fps, maxFrames, startMs, endMs)
            frames.forEach(onFrame)
        }
    }

    @Test
    fun `runs the session's trimmed range at the Workflow's rate`() = runBlocking {
        val frames = (0..60).map { frame(it, disc(100.0 + it * 5)) }
        val detector = FakeDetector(frames)

        val result = WorkflowDiscTracker(detector).track(session, emptyList())

        assertEquals(listOf("/clips/throw.mp4", 30.0, 61, 1_500L, 3_500L), detector.request)
        assertEquals((0..20).toList(), result.detections.map { it.frameIndex })
    }

    @Test
    fun `a model that cannot load is reported as such`() {
        val detector = object : FakeDetector(emptyList()) {
            override suspend fun loadModel() = throw IOException("missing weights.onnx")
        }

        assertThrows(DetectorModelUnavailableException::class.java) {
            runBlocking { WorkflowDiscTracker(detector).track(session, emptyList()) }
        }
    }

    @Test
    fun `an untrimmed session is capped at ten seconds`() {
        assertEquals(300, WorkflowDiscTracker.framesFor(session.copy(trimEndMs = null)))
    }
}
