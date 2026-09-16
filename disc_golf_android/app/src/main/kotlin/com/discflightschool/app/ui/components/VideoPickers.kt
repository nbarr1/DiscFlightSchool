package com.discflightschool.app.ui.components

import android.Manifest
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import com.discflightschool.app.LocalAppContainer
import java.io.File
import kotlinx.coroutines.launch

/**
 * Picking a clip from the device, or recording a new one.
 *
 * Both paths end the same way: the video is copied into app storage and the
 * caller is handed a plain file path. Everything downstream seeks the same file
 * hundreds of times, and a picker's content URI can lose its permission grant
 * between sessions.
 */
class VideoPickers internal constructor(
    private val onPick: () -> Unit,
    private val onRecord: () -> Unit,
) {
    /** Open the system photo picker, filtered to video. */
    fun pickFromLibrary() = onPick()

    /** Open the camera to record a new clip. */
    fun recordVideo() = onRecord()
}

/**
 * Wires up both launchers.
 *
 * [onVideoReady] receives the path of the imported clip; [onFailed] receives a
 * message to show when nothing came back — a cancelled picker and a denied
 * permission look the same to the caller, so the message says what to check.
 */
@Composable
fun rememberVideoPickers(
    onVideoReady: (String) -> Unit,
    onFailed: (String) -> Unit,
): VideoPickers {
    val container = LocalAppContainer.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    // Saved, not merely remembered: the camera is another app, and Android can
    // reclaim this process while it is in front. The result still arrives after
    // recreation, and without the path the recording would be reported as a
    // failure and left behind as an orphaned file.
    var captureTargetPath by rememberSaveable { mutableStateOf<String?>(null) }

    val pickLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia(),
    ) { uri: Uri? ->
        if (uri == null) {
            onFailed("No video selected.")
            return@rememberLauncherForActivityResult
        }
        scope.launch {
            val path = container.videoLibrary.importVideo(uri)
            if (path != null) {
                onVideoReady(path)
            } else {
                onFailed("That video could not be opened. Try a different clip.")
            }
        }
    }

    val captureLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CaptureVideo(),
    ) { saved ->
        val file = captureTargetPath?.let(::File)
        captureTargetPath = null
        if (saved && file != null && file.length() > 0) {
            container.videoLibrary.setCurrentVideo(file.absolutePath)
            onVideoReady(file.absolutePath)
        } else {
            file?.delete()
            onFailed("No video was recorded. Record a throw and confirm it.")
        }
    }

    val cameraPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (!granted) {
            onFailed("Camera permission is needed to record a throw.")
            return@rememberLauncherForActivityResult
        }
        val (file, uri) = container.videoLibrary.newCaptureTarget()
        captureTargetPath = file.absolutePath
        captureLauncher.launch(uri)
    }

    return remember(pickLauncher, captureLauncher, cameraPermissionLauncher) {
        VideoPickers(
            onPick = {
                pickLauncher.launch(
                    androidx.activity.result.PickVisualMediaRequest(
                        ActivityResultContracts.PickVisualMedia.VideoOnly,
                    ),
                )
            },
            onRecord = {
                val granted = ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.CAMERA,
                ) == PackageManager.PERMISSION_GRANTED

                if (granted) {
                    val (file, uri) = container.videoLibrary.newCaptureTarget()
                    captureTargetPath = file.absolutePath
                    captureLauncher.launch(uri)
                } else {
                    cameraPermissionLauncher.launch(Manifest.permission.CAMERA)
                }
            },
        )
    }
}
