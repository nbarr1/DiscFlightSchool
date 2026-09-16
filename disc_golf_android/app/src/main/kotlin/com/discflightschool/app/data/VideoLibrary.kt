package com.discflightschool.app.data

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.FileProvider
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext

/**
 * The videos the app is working with.
 *
 * A picked clip is copied into app storage before anything else touches it. The
 * pipeline seeks the same file hundreds of times during detection, and a
 * content URI handed over by a picker can have its permission revoked the
 * moment the process restarts — mid-analysis, that reads as a corrupt video
 * rather than as a lost permission.
 */
class VideoLibrary(private val context: Context) {

    private val videosDir: File = File(context.filesDir, "videos").apply { mkdirs() }

    private val _currentVideoPath = MutableStateFlow<String?>(null)
    val currentVideoPath: StateFlow<String?> = _currentVideoPath.asStateFlow()

    private val _recentVideos = MutableStateFlow<List<String>>(emptyList())
    val recentVideos: StateFlow<List<String>> = _recentVideos.asStateFlow()

    /** Copy [uri] into app storage and make it the current video. */
    suspend fun importVideo(uri: Uri): String? = withContext(Dispatchers.IO) {
        val destination = File(videosDir, "throw_${System.currentTimeMillis()}.mp4")
        val copied = runCatching {
            context.contentResolver.openInputStream(uri)?.use { input ->
                destination.outputStream().use { output -> input.copyTo(output) }
            } ?: return@runCatching false
            true
        }.getOrElse {
            Log.w(TAG, "Could not import the selected video", it)
            false
        }

        if (!copied || destination.length() == 0L) {
            destination.delete()
            return@withContext null
        }

        setCurrentVideo(destination.absolutePath)
        destination.absolutePath
    }

    /** A destination for a clip the camera is about to record. */
    fun newCaptureTarget(): Pair<File, Uri> {
        val file = File(videosDir, "capture_${System.currentTimeMillis()}.mp4")
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        return file to uri
    }

    fun setCurrentVideo(path: String) {
        _currentVideoPath.value = path
        addToRecent(path)
    }

    fun clearCurrentVideo() {
        _currentVideoPath.value = null
    }

    /** Every clip in app storage, newest first. */
    fun storedVideos(): List<File> = videosDir
        .listFiles { file -> file.isFile && isValidVideoFile(file.name) }
        ?.sortedByDescending { it.lastModified() }
        ?: emptyList()

    fun removeFromRecent(path: String) {
        _recentVideos.value = _recentVideos.value.filterNot { it == path }
    }

    fun videoExists(path: String): Boolean = runCatching { File(path).exists() }.getOrDefault(false)

    /** The size of a clip in megabytes, or null when it cannot be read. */
    fun videoSizeMb(path: String): Double? = runCatching {
        val file = File(path)
        if (file.exists()) file.length() / (1024.0 * 1024.0) else null
    }.getOrNull()

    fun deleteVideo(path: String): Boolean = runCatching {
        val file = File(path)
        if (!file.exists()) return@runCatching false
        val deleted = file.delete()
        if (deleted) {
            removeFromRecent(path)
            if (_currentVideoPath.value == path) _currentVideoPath.value = null
        }
        deleted
    }.getOrDefault(false)

    fun isValidVideoFile(path: String): Boolean =
        VIDEO_EXTENSIONS.any { path.lowercase().endsWith(it) }

    /**
     * Copy [file] into the device's shared Movies collection, so it survives
     * uninstalling the app and shows up in the gallery.
     */
    suspend fun saveToGallery(file: File, album: String = "Disc Flight School"): Boolean =
        withContext(Dispatchers.IO) {
            runCatching {
                val values = ContentValues().apply {
                    put(MediaStore.Video.Media.DISPLAY_NAME, file.name)
                    put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        put(
                            MediaStore.Video.Media.RELATIVE_PATH,
                            "${Environment.DIRECTORY_MOVIES}/$album",
                        )
                        put(MediaStore.Video.Media.IS_PENDING, 1)
                    }
                }

                val resolver = context.contentResolver
                val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                } else {
                    MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                }

                val uri = resolver.insert(collection, values) ?: return@runCatching false
                resolver.openOutputStream(uri)?.use { output ->
                    file.inputStream().use { input -> input.copyTo(output) }
                } ?: return@runCatching false

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    values.clear()
                    values.put(MediaStore.Video.Media.IS_PENDING, 0)
                    resolver.update(uri, values, null, null)
                }
                true
            }.getOrElse {
                Log.w(TAG, "Could not save ${file.name} to the gallery", it)
                false
            }
        }

    /** An intent that hands [file] to another app as a content URI. */
    fun shareIntent(file: File, mimeType: String): Intent {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        return Intent(Intent.ACTION_SEND).apply {
            type = mimeType
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    private fun addToRecent(path: String) {
        _recentVideos.value = (listOf(path) + _recentVideos.value.filterNot { it == path })
            .take(MAX_RECENT)
    }

    private companion object {
        const val TAG = "VideoLibrary"
        const val MAX_RECENT = 10
        val VIDEO_EXTENSIONS = listOf(".mp4", ".mov", ".avi", ".mkv", ".m4v")
    }
}
