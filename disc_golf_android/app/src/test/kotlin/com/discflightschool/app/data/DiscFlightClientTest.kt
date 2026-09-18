package com.discflightschool.app.data

import com.discflightschool.core.data.InMemoryKeyValueStore
import com.discflightschool.core.data.InMemoryManifestStore
import com.discflightschool.core.data.InMemorySecretStore
import com.discflightschool.core.data.TrainingDataRepository
import java.io.File
import kotlin.io.path.createTempDirectory
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class DiscFlightClientTest {
    private lateinit var server: MockWebServer
    private lateinit var temp: File
    private lateinit var video: File
    private lateinit var client: DiscFlightClient

    @Before
    fun setUp() {
        server = MockWebServer().also { it.start() }
        temp = createTempDirectory("disc-flight-client").toFile()
        video = File(temp, "throw.mp4").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val repository = TrainingDataRepository(
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

    private fun json(body: String) = MockResponse()
        .setResponseCode(200)
        .setHeader("Content-Type", "application/json")
        .setBody(body)
}
