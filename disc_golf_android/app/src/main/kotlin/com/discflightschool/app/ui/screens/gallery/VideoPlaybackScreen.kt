package com.discflightschool.app.ui.screens.gallery

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PauseCircleFilled
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.PlayCircleFilled
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.discflightschool.app.ui.Formatting
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.theme.AppColors
import com.discflightschool.app.video.VideoSurface
import com.discflightschool.app.video.rememberPlaybackState
import com.discflightschool.app.video.rememberVideoPlayer

/**
 * Full-screen playback with a scrubber, 100ms frame stepping, and slow motion.
 *
 * Quarter speed is there because a throw is over in well under a second: at 1x
 * there is nothing to see.
 */
@Composable
fun VideoPlaybackScreen(videoPath: String, onBack: () -> Unit) {
    val player = rememberVideoPlayer(videoPath, playWhenReady = true)
    val playback = rememberPlaybackState(player)
    var speed by remember { mutableFloatStateOf(1f) }

    Scaffold(
        topBar = { AppTopBar(title = "Playback", onBack = onBack) },
        containerColor = Color.Black,
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize(),
        ) {
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .clickable {
                        if (playback.isPlaying) player.pause() else player.play()
                    },
                contentAlignment = Alignment.Center,
            ) {
                VideoSurface(player, Modifier.fillMaxSize())
                if (!playback.isPlaying) {
                    Icon(
                        Icons.Default.PlayArrow,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier
                            .size(72.dp)
                            .background(Color.Black.copy(alpha = 0.35f), CircleShape)
                            .padding(12.dp),
                    )
                }
            }

            Column(
                modifier = Modifier
                    .background(Color.Black.copy(alpha = 0.85f))
                    .padding(start = 12.dp, top = 8.dp, end = 12.dp, bottom = 16.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        Formatting.clock(playback.positionMs),
                        style = MaterialTheme.typography.labelSmall,
                        color = Color.White,
                    )
                    Slider(
                        value = playback.positionMs.toFloat()
                            .coerceIn(0f, playback.durationMs.toFloat().coerceAtLeast(1f)),
                        onValueChange = { player.seekTo(it.toLong()) },
                        valueRange = 0f..playback.durationMs.toFloat().coerceAtLeast(1f),
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        Formatting.clock(playback.durationMs),
                        style = MaterialTheme.typography.labelSmall,
                        color = Color.White,
                    )
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceEvenly,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(
                        onClick = {
                            player.pause()
                            player.seekTo((playback.positionMs - FRAME_STEP_MS).coerceAtLeast(0))
                        },
                    ) {
                        Icon(
                            Icons.Default.SkipPrevious,
                            contentDescription = "Back 100 milliseconds",
                            tint = Color.White,
                        )
                    }

                    IconButton(
                        onClick = { if (playback.isPlaying) player.pause() else player.play() },
                    ) {
                        Icon(
                            if (playback.isPlaying) {
                                Icons.Default.PauseCircleFilled
                            } else {
                                Icons.Default.PlayCircleFilled
                            },
                            contentDescription = if (playback.isPlaying) "Pause" else "Play",
                            tint = Color.White,
                            modifier = Modifier.size(48.dp),
                        )
                    }

                    IconButton(
                        onClick = {
                            player.pause()
                            player.seekTo(
                                (playback.positionMs + FRAME_STEP_MS)
                                    .coerceAtMost(playback.durationMs),
                            )
                        },
                    ) {
                        Icon(
                            Icons.Default.SkipNext,
                            contentDescription = "Forward 100 milliseconds",
                            tint = Color.White,
                        )
                    }

                    TextButton(
                        onClick = {
                            speed = SPEEDS[(SPEEDS.indexOf(speed) + 1) % SPEEDS.size]
                            player.setPlaybackSpeed(speed)
                        },
                    ) {
                        Text(
                            "${speed}x",
                            color = AppColors.Accent,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }
            }
        }
    }
}

/** Roughly one frame at the 10fps the detection pipeline samples at. */
private const val FRAME_STEP_MS = 100L

private val SPEEDS = listOf(0.25f, 0.5f, 1f)
