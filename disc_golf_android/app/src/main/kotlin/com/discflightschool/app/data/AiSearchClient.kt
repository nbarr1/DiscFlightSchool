package com.discflightschool.app.data

import android.util.Log
import com.discflightschool.core.knowledge.ClaudeMessages
import com.discflightschool.core.model.KBStudy
import java.io.IOException
import java.net.SocketTimeoutException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * Asks Claude a question grounded in the bundled research library.
 *
 * Every outcome comes back as a sentence the screen can show. A failure here is
 * not exceptional — the user is on a phone, on their own API key — so a dead
 * network, a rejected key, and a refusal each get their own message rather than
 * an exception the UI has to interpret.
 */
class AiSearchClient(
    private val client: OkHttpClient = OkHttpClient.Builder()
        .callTimeout(ClaudeMessages.TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(ClaudeMessages.TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .build(),
    private val endpoint: String = ClaudeMessages.ENDPOINT,
) {

    suspend fun ask(
        question: String,
        apiKey: String,
        studies: List<KBStudy>,
    ): String = withContext(Dispatchers.IO) {
        if (apiKey.isBlank()) return@withContext ClaudeMessages.NO_API_KEY

        val request = Request.Builder()
            .url(endpoint)
            .addHeader("content-type", "application/json")
            .addHeader("x-api-key", apiKey)
            .addHeader("anthropic-version", ClaudeMessages.API_VERSION)
            .post(
                ClaudeMessages.requestBody(question, ClaudeMessages.systemPrompt(studies))
                    .toRequestBody(JSON_MEDIA_TYPE),
            )
            .build()

        try {
            client.newCall(request).execute().use { response ->
                ClaudeMessages.answerFromResponse(response.code, response.body?.string())
            }
        } catch (e: SocketTimeoutException) {
            ClaudeMessages.TIMEOUT_ERROR
        } catch (e: InterruptedException) {
            throw e
        } catch (e: IOException) {
            Log.w(TAG, "AI search request failed", e)
            // OkHttp reports a call timeout as a plain IOException, so the
            // message is what distinguishes it from an unreachable network.
            if (e.message?.contains("timeout", ignoreCase = true) == true) {
                ClaudeMessages.TIMEOUT_ERROR
            } else {
                ClaudeMessages.CONNECTION_ERROR
            }
        }
    }

    private companion object {
        const val TAG = "AiSearchClient"
        val JSON_MEDIA_TYPE = "application/json; charset=utf-8".toMediaType()
    }
}
