package com.discflightschool.app.ui.screens.gallery

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.FlightTakeoff
import androidx.compose.material.icons.filled.PlayCircleFilled
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.data.SavedFlightVideo
import com.discflightschool.app.ui.Formatting
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.components.EmptyState
import com.discflightschool.app.ui.theme.AppColors
import java.io.File
import kotlinx.coroutines.launch

/** Every flight path video exported from the tracker, newest first. */
@Composable
fun VideoGalleryScreen(onBack: () -> Unit) {
    val container = LocalAppContainer.current
    val repository = container.flightGalleryRepository
    val videos by repository.videos.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()

    var playing by remember { mutableStateOf<SavedFlightVideo?>(null) }
    var pendingDelete by remember { mutableStateOf<SavedFlightVideo?>(null) }

    LaunchedEffect(Unit) { repository.refresh() }

    val nowPlaying = playing
    if (nowPlaying != null) {
        VideoPlaybackScreen(
            videoPath = nowPlaying.path,
            onBack = { playing = null },
        )
        return
    }

    Scaffold(topBar = { AppTopBar(title = "Flight path gallery", onBack = onBack) }) { padding ->
        if (videos.isEmpty()) {
            EmptyState(
                icon = Icons.Default.VideoLibrary,
                title = "No saved flight path videos",
                message = "Export a video from Flight Tracker to see it here.",
                modifier = Modifier.padding(padding),
            )
            return@Scaffold
        }

        LazyColumn(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize(),
            contentPadding = PaddingValues(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(videos, key = { it.path }) { video ->
                VideoCard(
                    video = video,
                    onPlay = { playing = video },
                    onDelete = { pendingDelete = video },
                )
            }
        }
    }

    pendingDelete?.let { video ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete video") },
            text = {
                Text(
                    "Remove this video from the gallery? A copy saved to your device " +
                        "gallery is not affected.",
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingDelete = null
                        scope.launch { repository.delete(video) }
                    },
                ) {
                    Text("Delete", color = AppColors.Bad)
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun VideoCard(
    video: SavedFlightVideo,
    onPlay: () -> Unit,
    onDelete: () -> Unit,
) {
    val thumbnail = remember(video.thumbnailPath) {
        video.thumbnailPath
            ?.takeIf { File(it).exists() }
            ?.let { runCatching { BitmapFactory.decodeFile(it) }.getOrNull() }
    }
    val sizeLabel = remember(video.path) {
        val bytes = runCatching { File(video.path).length() }.getOrDefault(0L)
        if (bytes < 1024 * 1024) {
            "${bytes / 1024} KB"
        } else {
            "${Formatting.decimal(bytes / (1024.0 * 1024.0))} MB"
        }
    }

    Surface(
        shape = RoundedCornerShape(12.dp),
        color = AppColors.Surface,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.clickable(onClick = onPlay)) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(180.dp)
                    .background(AppColors.Background),
                contentAlignment = Alignment.Center,
            ) {
                if (thumbnail != null) {
                    Image(
                        bitmap = thumbnail.asImageBitmap(),
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    Icon(
                        Icons.Default.FlightTakeoff,
                        contentDescription = null,
                        tint = AppColors.Muted,
                        modifier = Modifier.size(48.dp),
                    )
                }
            }

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        Formatting.dateTime(video.savedAt),
                        fontWeight = FontWeight.Bold,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    Spacer(Modifier.height(2.dp))
                    Text(
                        sizeLabel,
                        style = MaterialTheme.typography.labelSmall,
                        color = AppColors.Muted,
                    )
                }
                IconButton(onClick = onPlay) {
                    Icon(
                        Icons.Default.PlayCircleFilled,
                        contentDescription = "Play",
                        tint = AppColors.FlightTracker,
                        modifier = Modifier.size(36.dp),
                    )
                }
                IconButton(onClick = onDelete) {
                    Icon(
                        Icons.Default.DeleteOutline,
                        contentDescription = "Delete",
                        tint = AppColors.Bad,
                    )
                }
            }
        }
    }
}
