package com.discflightschool.app.data

import com.discflightschool.core.data.InMemoryKeyValueStore
import com.discflightschool.core.data.InMemoryManifestStore
import com.discflightschool.core.data.InMemorySecretStore
import com.discflightschool.core.data.TrainingDataRepository
import java.io.File
import kotlin.io.path.createTempDirectory
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class DiscFlightClientTest {
    private lateinit var server: MockWebServer
    private lateinit var temp: File
    private lateinit var video: File
    private lateinit var client: DiscFlightClient
    private lateinit var repository: TrainingDataRepository

    @Before
    fun setUp() {
        server = MockWebServer().also { it.start() }
        temp = createTempDirectory("disc-flight-client").toFile()
        video = File(temp, "throw.mp4").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        repository = TrainingDataRepository(
            InMemoryKeyValueStore(),
            InMemorySecretStore(),
            InMemoryManifestStore(),
        ).apply {
            setServerUrl(server.url("/").toString())
            setApiKey("app-key")
        }
        client = DiscFlightClient(
            File(temp, "results"),
            repository,
            OkHttpClient(),
            pollDelayMs = 1,
        )
    }

    @After
    fun tearDown() {
        server.shutdown()
        temp.deleteRecursively()
    }

    @Test
    fun `upload processing progress and result playback path`() = runBlocking {
        server.enqueue(json("""{"jobId":"one","status":"queued","jobToken":"owner"}"""))
        server.enqueue(json("""{"jobId":"one","status":"processing","framesProcessed":4,"totalFrames":8,"progress":0.5}"""))
        server.enqueue(json("""{"jobId":"one","status":"complete","framesProcessed":8,"totalFrames":8,"progress":1.0}"""))
        server.enqueue(MockResponse().setResponseCode(200).setHeader("Content-Type", "video/mp4").setBody("mp4"))

        client.process(video.absolutePath)

        assertEquals(DiscFlightPhase.COMPLETE, client.state.value.phase)
        assertEquals(1.0, client.state.value.progress)
        assertTrue(File(checkNotNull(client.state.value.resultPath)).isFile)
        val upload = server.takeRequest()
        assertEquals("app-key", upload.getHeader("X-App-Key"))
        assertTrue(upload.body.readUtf8().contains("throw.mp4"))
        server.takeRequest()
        server.takeRequest()
        val download = server.takeRequest()
        assertEquals("owner", download.getHeader("X-Job-Token"))
    }

    @Test
    fun `server failure is rendered and retry succeeds`() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(503).setBody("""{"error":"Service unavailable"}"""))
        client.process(video.absolutePath)
        assertEquals(DiscFlightPhase.FAILED, client.state.value.phase)
        assertEquals("Service unavailable", client.state.value.error)

        server.enqueue(json("""{"jobId":"two","status":"queued","jobToken":"owner"}"""))
        server.enqueue(json("""{"jobId":"two","status":"complete","framesProcessed":1}"""))
        server.enqueue(MockResponse().setBody("mp4"))
        client.process(video.absolutePath)
        assertEquals(DiscFlightPhase.COMPLETE, client.state.value.phase)
    }

    @Test
    fun `duplicate submit is ignored while active and cancellation calls delete`() = runBlocking {
        server.enqueue(json("""{"jobId":"three","status":"queued","jobToken":"owner"}"""))
        server.enqueue(json("""{"jobId":"three","status":"processing","framesProcessed":1}"""))
        server.enqueue(json("""{"jobId":"three","status":"processing","framesProcessed":2}"""))
        val processing = async { client.process(video.absolutePath) }
        while (!client.state.value.active || server.requestCount < 2) delay(1)
        client.process(video.absolutePath)
        val beforeCancel = server.requestCount
        server.enqueue(json("""{"jobId":"three","status":"cancelled"}"""))
        client.cancel()
        processing.cancel()
        assertEquals(DiscFlightPhase.CANCELLED, client.state.value.phase)
        assertFalse(client.state.value.active)
        assertTrue(server.requestCount <= beforeCancel + 1)
    }

    // ── fetchTrack, for Auto-detect ──────────────────────────────────────

    @Test
    fun `fetchTrack sends the trimmed range and returns the track`() = runBlocking {
        server.enqueue(json("""{"jobId":"one","status":"queued","jobToken":"owner"}"""))
        server.enqueue(json("""{"jobId":"one","status":"processing","framesProcessed":30,"totalFrames":61,"progress":0.49}"""))
        server.enqueue(json("""{"jobId":"one","status":"complete","framesProcessed":61,"totalFrames":61}"""))
        server.enqueue(
            json(
                """{"fps":30.0,"frameCount":61,"detections":[
                   {"frame":0,"timeMs":0,"x":0.2,"y":0.5,"width":0.04,"height":0.07,"confidence":0.8}]}""",
            ),
        )
        val reported = mutableListOf<Pair<Double?, String>>()

        val track = client.fetchTrack(video.absolutePath, 1_500, 3_500) { fraction, status ->
            reported += fraction to status
        }

        assertEquals(1, track.points.size)
        assertEquals(0.2, track.points.single().x, 0.0)
        val upload = server.takeRequest()
        assertEquals("app-key", upload.getHeader("X-App-Key"))
        val form = upload.body.readUtf8()
        assertEquals("1500", formField(form, "start_ms"))
        assertEquals("3500", formField(form, "end_ms"))
        server.takeRequest()
        server.takeRequest()
        val trackRequest = server.takeRequest()
        assertEquals("/api/disc-flight/jobs/one/track", trackRequest.path)
        assertEquals("owner", trackRequest.getHeader("X-Job-Token"))
        assertTrue(0.49 to "Detecting disc: frame 30 of 61" in reported)
        // The screen's own tracing state is untouched.
        assertEquals(DiscFlightPhase.IDLE, client.state.value.phase)
    }

    @Test
    fun `fetchTrack leaves out end_ms for a range that runs to the end`() = runBlocking {
        server.enqueue(json("""{"jobId":"one","status":"queued","jobToken":"owner"}"""))
        server.enqueue(json("""{"jobId":"one","status":"complete"}"""))
        server.enqueue(json("""{"fps":30.0,"frameCount":0,"detections":[]}"""))

        client.fetchTrack(video.absolutePath, 0, null) { _, _ -> }

        val form = server.takeRequest().body.readUtf8()
        assertTrue(form.contains("name=\"start_ms\""))
        assertFalse(form.contains("end_ms"))
    }

    @Test
    fun `fetchTrack reports the server's reason for a failed job`() {
        server.enqueue(json("""{"jobId":"one","status":"queued","jobToken":"owner"}"""))
        server.enqueue(
            json("""{"jobId":"one","status":"failed","error":"The selected part of the video has no frames."}"""),
        )

        val error = assertThrows(IllegalStateException::class.java) {
            runBlocking { client.fetchTrack(video.absolutePath, 60_000, null) { _, _ -> } }
        }

        assertEquals("The selected part of the video has no frames.", error.message)
    }

    @Test
    fun `fetchTrack reports a refused key`() {
        server.enqueue(MockResponse().setResponseCode(403).setBody("""{"error":"Invalid or missing API key"}"""))

        val error = assertThrows(java.io.IOException::class.java) {
            runBlocking { client.fetchTrack(video.absolutePath, 0, null) { _, _ -> } }
        }

        assertEquals("Invalid or missing API key", error.message)
    }

    @Test
    fun `fetchTrack needs a key for a server other than the default`() {
        repository.clearApiKey()

        val error = assertThrows(IllegalStateException::class.java) {
            runBlocking { client.fetchTrack(video.absolutePath, 0, null) { _, _ -> } }
        }

        assertEquals("Set the app API key in Training Settings.", error.message)
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `cancelling fetchTrack deletes the job on the server`() = runBlocking {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when {
                request.method == "POST" -> json("""{"jobId":"one","status":"queued","jobToken":"owner"}""")
                request.method == "DELETE" -> json("""{"jobId":"one","status":"cancelled"}""")
                else -> json("""{"jobId":"one","status":"processing","framesProcessed":1}""")
            }
        }
        val fetch = async { client.fetchTrack(video.absolutePath, 0, null) { _, _ -> } }
        while (server.requestCount < 3) delay(1)

        fetch.cancel()
        // Lets the fetch run its cleanup before takeRequest blocks this thread.
        fetch.join()

        var delete: RecordedRequest? = null
        while (delete == null) {
            val request = server.takeRequest(5, TimeUnit.SECONDS) ?: break
            if (request.method == "DELETE") delete = request
        }
        assertEquals("/api/disc-flight/jobs/one", delete?.path)
        assertEquals("owner", delete?.getHeader("X-Job-Token"))
    }

    @Test
    fun `a finished fetchTrack leaves the job alone`() = runBlocking {
        server.enqueue(json("""{"jobId":"one","status":"queued","jobToken":"owner"}"""))
        server.enqueue(json("""{"jobId":"one","status":"complete"}"""))
        server.enqueue(json("""{"fps":30.0,"frameCount":0,"detections":[]}"""))

        client.fetchTrack(video.absolutePath, 0, null) { _, _ -> }

        repeat(3) { server.takeRequest() }
        assertNull(server.takeRequest(200, TimeUnit.MILLISECONDS))
    }

    /** The value of a plain text field in a multipart [form] body. */
    private fun formField(form: String, name: String): String? =
        Regex("""name="$name"\r\n(?:[^\r\n]+\r\n)*\r\n([^\r\n]*)\r\n""").find(form)?.groupValues?.get(1)

    private fun json(body: String) = MockResponse()
        .setResponseCode(200)
        .setHeader("Content-Type", "application/json")
        .setBody(body)
}
