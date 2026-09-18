package com.discflightschool.app.data

import com.discflightschool.core.data.TrainingDataRepository
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Call
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody

enum class DiscFlightPhase(val label: String) {
    IDLE("Ready"),
    PREPARING("Preparing upload"),
    UPLOADING("Uploading"),
    CONNECTING("Connecting"),
    PROCESSING("Processing"),
    FINALIZING("Finalizing"),
    COMPLETE("Complete"),
    FAILED("Failed"),
    CANCELLED("Cancelled"),
}

data class DiscFlightUiState(
    val phase: DiscFlightPhase = DiscFlightPhase.IDLE,
    val framesProcessed: Int = 0,
    val totalFrames: Int? = null,
    val progress: Double? = null,
    val resultPath: String? = null,
    val error: String? = null,
) {
    val active: Boolean get() = phase in setOf(
        DiscFlightPhase.PREPARING,
        DiscFlightPhase.UPLOADING,
        DiscFlightPhase.CONNECTING,
        DiscFlightPhase.PROCESSING,
        DiscFlightPhase.FINALIZING,
    )
}

/** Uploads and polls one backend-owned, stateful Roboflow video job. */
class DiscFlightClient(
    outputDirectory: File,
    private val settings: TrainingDataRepository,
    private val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(5, TimeUnit.MINUTES)
        .readTimeout(60, TimeUnit.SECONDS)
        .build(),
    private val pollDelayMs: Long = 1_000,
) {
    private val outputDir = outputDirectory.also { it.mkdirs() }
    private val json = Json { ignoreUnknownKeys = true }
    private val _state = MutableStateFlow(DiscFlightUiState())
    val state: StateFlow<DiscFlightUiState> = _state.asStateFlow()

    @Volatile private var activeCall: Call? = null
    @Volatile private var activeJobId: String? = null
    @Volatile private var activeJobToken: String? = null

    suspend fun process(videoPath: String) {
        if (_state.value.active) return
        val video = File(videoPath)
        _state.value = DiscFlightUiState(DiscFlightPhase.PREPARING)
        try {
            require(video.isFile && video.length() > 0) { "The selected video is unavailable." }
            val endpoint = settings.endpoint("/api/disc-flight/jobs")
                ?: error("Set a valid server URL in Training Settings.")
            val apiKey = settings.apiKey.takeIf { it.isNotBlank() }
                ?: error("Set the app API key in Training Settings.")
            _state.value = DiscFlightUiState(DiscFlightPhase.UPLOADING)
            val request = Request.Builder()
                .url(endpoint.toString())
                .header("X-App-Key", apiKey)
                .post(
                    MultipartBody.Builder().setType(MultipartBody.FORM)
                        .addFormDataPart(
                            "video",
                            video.name,
                            video.asRequestBody(mediaType(video)),
                        )
                        .build(),
                )
                .build()
            val start = execute(request)
            activeJobId = string(start, "jobId") ?: error("Server omitted the job ID.")
            activeJobToken = string(start, "jobToken") ?: error("Server omitted the job token.")
            _state.value = DiscFlightUiState(DiscFlightPhase.CONNECTING)
            poll(apiKey)
        } catch (cancelled: CancellationException) {
            _state.value = DiscFlightUiState(DiscFlightPhase.CANCELLED)
            throw cancelled
        } catch (error: Exception) {
            if (_state.value.phase != DiscFlightPhase.CANCELLED) {
                _state.value = DiscFlightUiState(
                    phase = DiscFlightPhase.FAILED,
                    error = error.message ?: "The video could not be processed.",
                )
            }
        } finally {
            activeCall = null
        }
    }

    suspend fun cancel() {
        activeCall?.cancel()
        val id = activeJobId
        val token = activeJobToken
        _state.value = DiscFlightUiState(DiscFlightPhase.CANCELLED)
        if (id != null && token != null) {
            settings.endpoint("/api/disc-flight/jobs/$id")?.let { endpoint ->
                runCatching {
                    execute(
                        Request.Builder().url(endpoint.toString())
                            .header("X-App-Key", settings.apiKey)
                            .header("X-Job-Token", token)
                            .delete().build(),
                    )
                }
            }
        }
        activeJobId = null
        activeJobToken = null
    }

    fun reset() {
        if (!_state.value.active) _state.value = DiscFlightUiState()
    }

    private suspend fun poll(apiKey: String) {
        val id = checkNotNull(activeJobId)
        val token = checkNotNull(activeJobToken)
        val endpoint = settings.endpoint("/api/disc-flight/jobs/$id")
            ?: error("The server URL changed while processing.")
        while (true) {
            val body = execute(
                Request.Builder().url(endpoint.toString())
                    .header("X-App-Key", apiKey).header("X-Job-Token", token).build(),
            )
            val status = string(body, "status") ?: "processing"
            val frames = int(body, "framesProcessed") ?: 0
            val total = int(body, "totalFrames")
            val progress = double(body, "progress")
            when (status) {
                "queued", "connecting" -> _state.value = DiscFlightUiState(DiscFlightPhase.CONNECTING, frames, total, progress)
                "processing" -> _state.value = DiscFlightUiState(DiscFlightPhase.PROCESSING, frames, total, progress)
                "finalizing" -> _state.value = DiscFlightUiState(DiscFlightPhase.FINALIZING, frames, total, progress)
                "complete" -> {
                    _state.value = DiscFlightUiState(DiscFlightPhase.FINALIZING, frames, total, progress)
                    val path = download(apiKey, token, id)
                    _state.value = DiscFlightUiState(DiscFlightPhase.COMPLETE, frames, total, 1.0, path)
                    activeJobId = null
                    activeJobToken = null
                    return
                }
                "cancelled" -> {
                    _state.value = DiscFlightUiState(DiscFlightPhase.CANCELLED)
                    return
                }
                "failed" -> error(string(body, "error") ?: "Disc processing failed.")
                else -> error("Server returned an unknown processing state.")
            }
            delay(pollDelayMs)
        }
    }

    private suspend fun download(apiKey: String, token: String, id: String): String {
        val endpoint = settings.endpoint("/api/disc-flight/jobs/$id/result")
            ?: error("The result URL is invalid.")
        val request = Request.Builder().url(endpoint.toString())
            .header("X-App-Key", apiKey).header("X-Job-Token", token).build()
        return withContext(Dispatchers.IO) {
            val call = http.newCall(request)
            activeCall = call
            call.execute().use { response ->
                if (!response.isSuccessful) throw IOException(serverError(response.body?.string(), response.code))
                val destination = File(outputDir, "$id.mp4")
                response.body?.byteStream()?.use { input ->
                    destination.outputStream().use(input::copyTo)
                } ?: throw IOException("The server returned an empty result.")
                destination.absolutePath
            }
        }
    }

    private suspend fun execute(request: Request): String = withContext(Dispatchers.IO) {
        val call = http.newCall(request)
        activeCall = call
        call.execute().use { response ->
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful) throw IOException(serverError(body, response.code))
            body
        }
    }

    private fun serverError(body: String?, code: Int): String = runCatching {
        string(body.orEmpty(), "error")
    }.getOrNull() ?: "Server request failed ($code)."

    private fun mediaType(file: File) = when (file.extension.lowercase()) {
        "mov" -> "video/quicktime"
        "webm" -> "video/webm"
        "mkv" -> "video/x-matroska"
        else -> "video/mp4"
    }.toMediaType()

    private fun string(body: String, key: String) =
        json.parseToJsonElement(body).jsonObject[key]?.jsonPrimitive?.content
    private fun int(body: String, key: String) =
        json.parseToJsonElement(body).jsonObject[key]?.jsonPrimitive?.intOrNull
    private fun double(body: String, key: String) =
        json.parseToJsonElement(body).jsonObject[key]?.jsonPrimitive?.doubleOrNull
}
