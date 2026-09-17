package com.discflightschool.app.ui.screens.flighttracker

import android.content.Intent
import androidx.core.content.FileProvider
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForwardIos
import androidx.compose.material.icons.filled.UploadFile
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.components.rememberVideoPickers
import com.discflightschool.app.ui.theme.AppColors
import com.discflightschool.app.data.DiscFlightPhase
import com.discflightschool.app.video.VideoStage
import com.discflightschool.app.video.rememberVideoPlayer
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.platform.LocalContext
import java.io.File
import kotlinx.coroutines.launch

/** Brings a clip in, then hands it to the trimmer before tracking starts. */
@Composable
fun FlightTrackerScreen(onBack: () -> Unit, onVideoSelected: () -> Unit) {
    val container = LocalAppContainer.current
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val snackbarHostState = remember { SnackbarHostState() }
    val processing by container.discFlightClient.state.collectAsStateWithLifecycle()
    var selectedPath by remember { mutableStateOf<String?>(null) }

    val pickers = rememberVideoPickers(
        onVideoReady = { path ->
            container.workbench.startFlightSession(path)
            container.discFlightClient.reset()
            selectedPath = path
        },
        onFailed = { message -> scope.launch { snackbarHostState.showSnackbar(message) } },
    )

    Scaffold(
        topBar = {
            AppTopBar(
                title = "Flight Tracker",
                onBack = {
                    if (processing.active) {
                        scope.launch {
                            container.discFlightClient.cancel()
                            onBack()
                        }
                    } else {
                        onBack()
                    }
                },
            )
        },
        snackbarHost = { SnackbarHost(snackbarHostState) },
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            Text(
                "Track disc flight",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(8.dp))
            Text(
                "Record or upload a video to map the flight path.",
                style = MaterialTheme.typography.bodyMedium,
                color = AppColors.Muted,
            )
            Spacer(Modifier.height(24.dp))

            selectedPath?.let { path ->
                val player = rememberVideoPlayer(processing.resultPath ?: path)
                VideoStage(
                    player = player,
                    modifier = Modifier.fillMaxWidth().height(240.dp),
                )
                Spacer(Modifier.height(12.dp))
                Text(
                    processing.phase.label,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                )
                when {
                    processing.progress != null -> LinearProgressIndicator(
                        progress = { processing.progress!!.toFloat() },
                        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                    )
                    processing.active -> LinearProgressIndicator(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                    )
                }
                if (processing.framesProcessed > 0) {
                    Text(
                        processing.totalFrames?.let { "${processing.framesProcessed} of $it frames" }
                            ?: "${processing.framesProcessed} frames processed",
                        color = AppColors.Muted,
                    )
                }
                processing.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                Spacer(Modifier.height(12.dp))
                Row(horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp)) {
                    if (!processing.active && processing.phase != DiscFlightPhase.COMPLETE) {
                        Button(onClick = { scope.launch { container.discFlightClient.process(path) } }) {
                            Icon(Icons.Default.CloudUpload, contentDescription = null)
                            Spacer(Modifier.width(8.dp))
                            Text(if (processing.phase == DiscFlightPhase.FAILED) "Retry" else "Trace in cloud")
                        }
                    }
                    if (processing.active) {
                        OutlinedButton(onClick = { scope.launch { container.discFlightClient.cancel() } }) {
                            Text("Cancel")
                        }
                    }
                    if (processing.phase == DiscFlightPhase.COMPLETE && processing.resultPath != null) {
                        OutlinedButton(onClick = {
                            val result = File(processing.resultPath!!)
                            val uri = FileProvider.getUriForFile(
                                context,
                                "${context.packageName}.fileprovider",
                                result,
                            )
                            context.startActivity(
                                Intent.createChooser(
                                    Intent(Intent.ACTION_SEND).apply {
                                        type = "video/mp4"
                                        putExtra(Intent.EXTRA_STREAM, uri)
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    },
                                    "Share traced throw",
                                ),
                            )
                        }) {
                            Icon(Icons.Default.Share, contentDescription = null)
                            Spacer(Modifier.width(8.dp))
                            Text("Share")
                        }
                    }
                }
                Spacer(Modifier.height(8.dp))
                OutlinedButton(
                    enabled = !processing.active,
                    onClick = onVideoSelected,
                ) { Text("Use on-device tracker") }
                Spacer(Modifier.height(24.dp))
            }

            ActionCard(
                title = "Record video",
                description = "Use the camera to record a throw",
                icon = Icons.Default.Videocam,
                accent = AppColors.Bad,
                enabled = !processing.active,
                onClick = { pickers.recordVideo() },
            )
            Spacer(Modifier.height(16.dp))
            ActionCard(
                title = "Upload video",
                description = "Select a video from your device",
                icon = Icons.Default.UploadFile,
                accent = AppColors.FlightTracker,
                enabled = !processing.active,
                onClick = { pickers.pickFromLibrary() },
            )
        }
    }
}

@Composable
private fun ActionCard(
    title: String,
    description: String,
    icon: ImageVector,
    accent: Color,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = AppColors.Surface,
        tonalElevation = 4.dp,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier
                .clickable(enabled = enabled, onClick = onClick)
                .padding(20.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Surface(shape = RoundedCornerShape(12.dp), color = accent.copy(alpha = 0.2f)) {
                Icon(
                    icon,
                    contentDescription = null,
                    tint = accent,
                    modifier = Modifier
                        .padding(12.dp)
                        .size(32.dp),
                )
            }
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    title,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    description,
                    style = MaterialTheme.typography.bodySmall,
                    color = AppColors.Muted,
                )
            }
            Icon(
                Icons.AutoMirrored.Filled.ArrowForwardIos,
                contentDescription = null,
                tint = AppColors.Muted,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}
