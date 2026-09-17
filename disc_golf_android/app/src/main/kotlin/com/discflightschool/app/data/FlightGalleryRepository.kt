package com.discflightschool.app.data

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import com.discflightschool.core.data.KeyValueStore
import com.discflightschool.core.util.DateTimes
import java.io.File
import java.time.Instant
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** One exported flight path video kept inside the app. */
data class SavedFlightVideo(
    val path: String,
    val savedAt: Instant,
    val thumbnailPath: String? = null,
) {
    fun toJson(): JsonObject = buildJsonObject {
        put("path", JsonPrimitive(path))
        put("savedAt", JsonPrimitive(DateTimes.format(savedAt)))
        put("thumbnailPath", thumbnailPath?.let { JsonPrimitive(it) } ?: JsonNull)
    }

    companion object {
        fun fromJson(json: JsonObject): SavedFlightVideo = SavedFlightVideo(
            path = json.getValue("path").jsonPrimitive.content,
            savedAt = DateTimes.parse(json.getValue("savedAt").jsonPrimitive.content),
            thumbnailPath = json["thumbnailPath"]?.takeIf { it !is JsonNull }
                ?.jsonPrimitive?.content,
        )
    }
}

/**
 * The app's own copy of every exported flight video.
 *
 * Separate from the device gallery on purpose: the export flow also offers to
 * save to Movies, and a user who deletes it there should still find it here —
 * and deleting it here must not reach into their gallery.
 */
class FlightGalleryRepository(
    private val context: Context,
    private val store: KeyValueStore,
    private val frameExtractor: com.discflightschool.app.video.FrameExtractor,
) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val galleryDir: File = File(context.filesDir, "flight_gallery")

    private val _videos = MutableStateFlow<List<SavedFlightVideo>>(emptyList())
    val videos: StateFlow<List<SavedFlightVideo>> = _videos.asStateFlow()

    /** Load the registry, dropping entries whose file is gone. */
    suspend fun refresh() = withContext(Dispatchers.IO) {
        val stored = store.getStringList(KEY).orEmpty()
        val videos = stored.mapNotNull { entry ->
            runCatching {
                SavedFlightVideo.fromJson(json.parseToJsonElement(entry).jsonObject)
            }.getOrNull()
        }.filter { File(it.path).exists() }

        _videos.value = videos
        persist()
    }

    /** Copy an exported clip into the gallery and register it. */
    suspend fun save(sourcePath: String): String? = withContext(Dispatchers.IO) {
        runCatching {
            galleryDir.mkdirs()
            val destination = File(galleryDir, "flight_${System.currentTimeMillis()}.mp4")
            File(sourcePath).copyTo(destination, overwrite = true)

            val thumbnail = runCatching {
                frameExtractor.frameBitmapAt(destination.absolutePath, 0)?.let { bitmap ->
                    val thumbFile = File(galleryDir, "${destination.nameWithoutExtension}.jpg")
                    thumbFile.outputStream().use {
                        bitmap.compress(Bitmap.CompressFormat.JPEG, 75, it)
                    }
                    bitmap.recycle()
                    thumbFile.absolutePath
                }
            }.getOrNull()

            val video = SavedFlightVideo(
                path = destination.absolutePath,
                savedAt = Instant.now(),
                thumbnailPath = thumbnail,
            )
            _videos.value = listOf(video) + _videos.value
            persist()
            destination.absolutePath
        }.onFailure { Log.w(TAG, "Failed to save an exported flight video", it) }.getOrNull()
    }

    /** Remove a clip from the app's gallery, leaving the device gallery alone. */
    suspend fun delete(video: SavedFlightVideo) = withContext(Dispatchers.IO) {
        runCatching { File(video.path).delete() }
        video.thumbnailPath?.let { runCatching { File(it).delete() } }
        _videos.value = _videos.value.filterNot { it.path == video.path }
        persist()
    }

    private fun persist() {
        store.putStringList(KEY, _videos.value.map { it.toJson().toString() })
    }

    private companion object {
        const val TAG = "FlightGalleryRepository"
        const val KEY = "saved_flight_videos"
    }
}
