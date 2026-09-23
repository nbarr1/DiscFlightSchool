package com.discflightschool.app.data

import com.discflightschool.core.data.TrainingDataRepository
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.math.roundToInt
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

/** One disc the server found, in pixels of the uploaded image. `x`/`y` is the box center. */
@Serializable
data class CloudDiscBox(
    val x: Double,
    val y: Double,
    val width: Double,
    val height: Double,
    val confidence: Double,
    val className: String,
)

/** The server's answer for one image. */
@Serializable
data class CloudDiscDetections(
    val imageWidth: Int,
    val imageHeight: Int,
    val detections: List<CloudDiscBox>,
)

/** "Found 1 disc (82% confidence)." or "No disc found in this photo." */
fun CloudDiscDetections.summary(): String {
    val best = detections.maxByOrNull { it.confidence } ?: return "No disc found in this photo."
    val percent = (best.confidence * 100).roundToInt()
    return if (detections.size == 1) {
        "Found 1 disc ($percent% confidence)."
    } else {
        "Found ${detections.size} discs (best $percent% confidence)."
    }
}

/**
 * Sends one JPEG to the server's `POST /api/disc-detection`, which runs it
 * through the Roboflow disc-detection Workflow.
 *
 * Only the app API key leaves the device. The Roboflow key stays on the server.
 */
class DiscDetectionClient(
    private val settings: TrainingDataRepository,
    private val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        // The server retries Roboflow itself and can take about 90 seconds
        // to give up with a 504, so this must outlast that.
        .readTimeout(120, TimeUnit.SECONDS)
        .build(),
) {
    private val json = Json { ignoreUnknownKeys = true }

    /** Detect discs in [jpeg]. Failures throw with a message fit to show the user. */
    suspend fun detect(jpeg: ByteArray): CloudDiscDetections {
        val endpoint = settings.endpoint("/api/disc-detection")
            ?: error("Set a valid server URL in Training Settings.")
        val apiKey = settings.apiKey.takeIf { it.isNotBlank() }
            ?: error("Set the app API key in Training Settings.")
        val request = Request.Builder()
            .url(endpoint.toString())
            .header("X-App-Key", apiKey)
            .post(
                MultipartBody.Builder().setType(MultipartBody.FORM)
                    .addFormDataPart("image", "photo.jpg", jpeg.toRequestBody(JPEG))
                    .build(),
            )
            .build()
        val (code, body) = http.newCall(request).await()
        if (code !in 200..299) throw IOException(serverError(body, code))
        return try {
            json.decodeFromString<CloudDiscDetections>(body)
        } catch (e: IllegalArgumentException) {
            throw IOException("The server returned an unexpected response.", e)
        }
    }

    private fun serverError(body: String, code: Int): String = runCatching {
        json.parseToJsonElement(body).jsonObject["error"]?.jsonPrimitive?.content
    }.getOrNull() ?: "Server request failed ($code)."

    private companion object {
        val JPEG = "image/jpeg".toMediaType()
    }
}

/**
 * Runs the call on OkHttp's own threads and returns its status and body.
 * Cancelling the caller cancels the request, so leaving the screen doesn't
 * leave a detection running.
 */
private suspend fun Call.await(): Pair<Int, String> = suspendCancellableCoroutine { continuation ->
    continuation.invokeOnCancellation { cancel() }
    enqueue(
        object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                continuation.resumeWith(Result.failure(e))
            }

            override fun onResponse(call: Call, response: Response) {
                continuation.resumeWith(
                    runCatching { response.use { it.code to it.body?.string().orEmpty() } },
                )
            }
        },
    )
}
