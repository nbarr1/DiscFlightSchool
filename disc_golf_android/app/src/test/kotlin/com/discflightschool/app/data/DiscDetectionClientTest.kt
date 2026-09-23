package com.discflightschool.app.data

import com.discflightschool.core.data.InMemoryKeyValueStore
import com.discflightschool.core.data.InMemoryManifestStore
import com.discflightschool.core.data.InMemorySecretStore
import com.discflightschool.core.data.TrainingDataRepository
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class DiscDetectionClientTest {
    private lateinit var server: MockWebServer
    private lateinit var repository: TrainingDataRepository
    private lateinit var client: DiscDetectionClient

    private val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 1, 2, 3)

    @Before
    fun setUp() {
        server = MockWebServer().also { it.start() }
        repository = TrainingDataRepository(
            InMemoryKeyValueStore(),
            InMemorySecretStore(),
            InMemoryManifestStore(),
        ).apply {
            setServerUrl(server.url("/").toString())
            setApiKey("app-key")
        }
        client = DiscDetectionClient(repository, OkHttpClient())
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun `uploads the photo and parses the server's detections`() = runBlocking {
        // The body the server returns for the frame captured from the real Workflow.
        server.enqueue(
            json(
                """{"imageWidth":576,"imageHeight":1024,"detections":[{"x":228.0,"y":521.0,""" +
                    """"width":40.0,"height":22.0,"confidence":0.8215,"className":"disc"}]}""",
            ),
        )

        val result = client.detect(jpeg)

        assertEquals(576, result.imageWidth)
        assertEquals(1024, result.imageHeight)
        assertEquals(listOf(CloudDiscBox(228.0, 521.0, 40.0, 22.0, 0.8215, "disc")), result.detections)
        val request = server.takeRequest()
        assertEquals("/api/disc-detection", request.path)
        assertEquals("app-key", request.getHeader("X-App-Key"))
        val body = request.body.readUtf8()
        assertTrue(body.contains("name=\"image\"; filename=\"photo.jpg\""))
        assertTrue(body.contains("Content-Type: image/jpeg"))
    }

    @Test
    fun `server error message is shown as is`() {
        server.enqueue(
            MockResponse().setResponseCode(503)
                .setBody("""{"error":"Roboflow processing is not configured on this server"}"""),
        )
        val error = assertThrows(IOException::class.java) { runBlocking { client.detect(jpeg) } }
        assertEquals("Roboflow processing is not configured on this server", error.message)
    }

    @Test
    fun `an error without a JSON body falls back to the status code`() {
        server.enqueue(MockResponse().setResponseCode(502).setBody("<html>Bad gateway</html>"))
        val error = assertThrows(IOException::class.java) { runBlocking { client.detect(jpeg) } }
        assertEquals("Server request failed (502).", error.message)
    }

    @Test
    fun `an unexpected success body is an error rather than an empty result`() {
        server.enqueue(json("""{"predictions":[]}"""))
        val error = assertThrows(IOException::class.java) { runBlocking { client.detect(jpeg) } }
        assertEquals("The server returned an unexpected response.", error.message)
    }

    @Test
    fun `missing API key fails before any request`() {
        repository.clearApiKey()
        val error = assertThrows(IllegalStateException::class.java) { runBlocking { client.detect(jpeg) } }
        assertEquals("Set the app API key in Training Settings.", error.message)
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `cancelling the caller does not wait for the server`() {
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
        val started = System.nanoTime()
        assertThrows(TimeoutCancellationException::class.java) {
            runBlocking { withTimeout(200) { client.detect(jpeg) } }
        }
        assertTrue(TimeUnit.NANOSECONDS.toSeconds(System.nanoTime() - started) < 5)
    }

    @Test
    fun `summary names the count and best confidence`() {
        fun box(confidence: Double) = CloudDiscBox(0.0, 0.0, 1.0, 1.0, confidence, "disc")
        assertEquals("No disc found in this photo.", CloudDiscDetections(1, 1, emptyList()).summary())
        assertEquals("Found 1 disc (82% confidence).", CloudDiscDetections(1, 1, listOf(box(0.8215))).summary())
        assertEquals(
            "Found 2 discs (best 74% confidence).",
            CloudDiscDetections(1, 1, listOf(box(0.4), box(0.74))).summary(),
        )
    }

    private fun json(body: String) = MockResponse()
        .setResponseCode(200)
        .setHeader("Content-Type", "application/json")
        .setBody(body)
}
