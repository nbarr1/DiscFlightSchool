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
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.ui.Formatting
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.components.VideoWithControls
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
    confirmIcon: ImageVector = Icons.Default.Flag,
    /** What comes after the trim, under the slider; given the frame count. */
    nextStepHint: (frameCount: Int) -> String = {
        "$it frames · next, mark the four key throw phases"
    },
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
        // A zero-length range is reachable by dragging the thumbs together, and
        // nothing downstream can analyse or track it.
        val tooShort = endMs - startMs < MIN_RANGE_MS

        VideoWithControls(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize(),
            video = { videoModifier ->
                Box(
                    modifier = videoModifier.background(Color.Black),
                    contentAlignment = Alignment.Center,
                ) {
                    VideoSurface(player, Modifier.fillMaxSize())
                }
            },
            controls = {
                Column(Modifier.fillMaxWidth().padding(16.dp)) {
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
                        TextButton(
                            onClick = { player.seekTo(startMs) },
                            colors = ButtonDefaults.textButtonColors(contentColor = AppColors.Good),
                        ) {
                            Text("Start ${seconds(startMs)}", fontWeight = FontWeight.Bold)
                        }
                        Text(
                            seconds(endMs - startMs),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.semantics {
                                contentDescription = "Selection length ${seconds(endMs - startMs)}"
                            },
                        )
                        TextButton(
                            onClick = { player.seekTo(endMs) },
                            colors = ButtonDefaults.textButtonColors(contentColor = AppColors.Bad),
                        ) {
                            Text("End ${seconds(endMs)}", fontWeight = FontWeight.Bold)
                        }
                    }

                    RangeSlider(
                        value = range,
                        onValueChange = { range = it },
                        onValueChangeFinished = { player.seekTo(range.start.toLong()) },
                        valueRange = 0f..durationMs,
                    )

                    Text(
                        if (tooShort) {
                            "Drag the handles apart to select at least half a second."
                        } else {
                            nextStepHint(frameCount)
                        },
                        style = MaterialTheme.typography.labelMedium,
                        color = if (tooShort) AppColors.Warning else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.fillMaxWidth(),
                        textAlign = TextAlign.Center,
                    )

                    Spacer(Modifier.height(16.dp))

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
                            enabled = !tooShort,
                            modifier = Modifier.weight(2f),
                        ) {
                            Icon(confirmIcon, contentDescription = null)
                            Spacer(Modifier.width(8.dp))
                            Text(confirmLabel)
                        }
                    }
                }
            },
        )
    }
}

private fun seconds(millis: Long) = "${Formatting.decimal(millis / 1000.0)}s"

/** One frame every [FrameExtractor.POSE_INTERVAL_MS], capped at 300. */
internal fun frameCountFor(startMs: Long, endMs: Long): Int =
    ceil((endMs - startMs).toDouble() / FrameExtractor.POSE_INTERVAL_MS)
        .toInt()
        .coerceIn(1, 300)

private const val DEFAULT_RANGE_MS = 6000f

private const val MIN_RANGE_MS = 500L
