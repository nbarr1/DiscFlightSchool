package com.discflightschool.app.ui.screens.formcoach

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RangeSlider
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.ui.Formatting
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.components.LoadingState
import com.discflightschool.app.ui.theme.AppColors
import com.discflightschool.app.video.FrameExtractor
import com.discflightschool.app.video.VideoSurface
import com.discflightschool.app.video.rememberPlaybackState
import com.discflightschool.app.video.rememberVideoPlayer
import kotlin.math.ceil

/**
 * Picks the part of a clip worth analysing.
 *
 * A phone recording is mostly walk-up and celebration; the throw itself is
 * about a second. Analysing the whole file costs one inference per frame for
 * footage with no throw in it, so the range is chosen first and every frame
 * index downstream is relative to its start.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VideoTrimScreen(
    videoPath: String,
    title: String = "Trim video",
    confirmLabel: String = "Select phases",
    onBack: () -> Unit,
    onConfirm: (startMs: Long, endMs: Long, frameCount: Int) -> Unit,
) {
    val container = LocalAppContainer.current
    val player = rememberVideoPlayer(videoPath)
    val playback = rememberPlaybackState(player)

    var durationMs by remember { mutableFloatStateOf(0f) }
    var range by remember { mutableStateOf(0f..0f) }
    var previewEndMs by remember { mutableStateOf<Long?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(videoPath) {
        val duration = container.frameExtractor.durationMs(videoPath)
        if (duration == null || duration <= 0) {
            error = "Could not read this video. Check that it is a supported format."
            return@LaunchedEffect
        }
        durationMs = duration.toFloat()
        // Default to the first six seconds, or the whole clip when it is shorter.
        range = 0f..minOf(duration.toFloat(), DEFAULT_RANGE_MS)
    }

    // Preview plays only the selection, then stops at its end.
    LaunchedEffect(playback.positionMs, previewEndMs) {
        val end = previewEndMs ?: return@LaunchedEffect
        if (playback.positionMs >= end) {
            player.pause()
            previewEndMs = null
        }
    }

    Scaffold(topBar = { AppTopBar(title = title, onBack = onBack) }) { padding ->
        val message = error
        if (message != null) {
            Column(
                modifier = Modifier
                    .padding(padding)
                    .fillMaxSize()
                    .padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Text(message, textAlign = TextAlign.Center)
                Spacer(Modifier.height(16.dp))
                Button(onClick = onBack) { Text("Go back") }
            }
            return@Scaffold
        }

        if (durationMs <= 0f) {
            LoadingState("Loading video...", Modifier.padding(padding))
            return@Scaffold
        }

        val startMs = range.start.toLong()
        val endMs = range.endInclusive.toLong()
        val frameCount = frameCountFor(startMs, endMs)

        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize(),
        ) {
            Box(
                modifier = Modifier
                    .weight(3f)
                    .fillMaxWidth()
                    .background(Color.Black),
                contentAlignment = Alignment.Center,
            ) {
                VideoSurface(player, Modifier.fillMaxSize())
            }

            Column(
                modifier = Modifier
                    .weight(2f)
                    .fillMaxWidth()
                    .padding(16.dp),
            ) {
                Text(
                    "Select the analysis range",
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.fillMaxWidth(),
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(8.dp))

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(
                        "Start: ${seconds(startMs)}",
                        fontWeight = FontWeight.Bold,
                        color = AppColors.Good,
                        modifier = Modifier.clickable { player.seekTo(startMs) },
                    )
                    Text(
                        "Duration: ${seconds(endMs - startMs)}",
                        color = AppColors.Muted,
                    )
                    Text(
                        "End: ${seconds(endMs)}",
                        fontWeight = FontWeight.Bold,
                        color = AppColors.Bad,
                        modifier = Modifier.clickable { player.seekTo(endMs) },
                    )
                }

                RangeSlider(
                    value = range,
                    onValueChange = { range = it },
                    onValueChangeFinished = { player.seekTo(range.start.toLong()) },
                    valueRange = 0f..durationMs,
                )

                Text(
                    "$frameCount frames · next: mark the four key throw phases",
                    style = MaterialTheme.typography.labelMedium,
                    color = AppColors.Muted,
                    modifier = Modifier.fillMaxWidth(),
                    textAlign = TextAlign.Center,
                )

                Spacer(Modifier.weight(1f))

                Row(Modifier.fillMaxWidth()) {
                    OutlinedButton(
                        onClick = {
                            player.seekTo(startMs)
                            previewEndMs = endMs
                            player.play()
                        },
                        modifier = Modifier.weight(1f),
                    ) {
                        Icon(Icons.Default.PlayArrow, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Text("Preview")
                    }
                    Spacer(Modifier.width(12.dp))
                    Button(
                        onClick = { onConfirm(startMs, endMs, frameCount) },
                        modifier = Modifier.weight(2f),
                    ) {
                        Icon(
                            if (confirmLabel == "Use selection") {
                                Icons.Default.Check
                            } else {
                                Icons.Default.Flag
                            },
                            contentDescription = null,
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(confirmLabel)
                    }
                }
            }
        }
    }
}

private fun seconds(millis: Long) = "${Formatting.decimal(millis / 1000.0)}s"

/** One frame every [FrameExtractor.POSE_INTERVAL_MS], capped at 300. */
internal fun frameCountFor(startMs: Long, endMs: Long): Int =
    ceil((endMs - startMs).toDouble() / FrameExtractor.POSE_INTERVAL_MS)
        .toInt()
        .coerceIn(1, 300)

private const val DEFAULT_RANGE_MS = 6000f
