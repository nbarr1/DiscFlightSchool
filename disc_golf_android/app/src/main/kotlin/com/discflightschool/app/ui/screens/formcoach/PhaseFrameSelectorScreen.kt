package com.discflightschool.app.ui.screens.formcoach

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Redo
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.FastForward
import androidx.compose.material.icons.filled.FastRewind
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.PauseCircle
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.RocketLaunch
import androidx.compose.material.icons.filled.RotateRight
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.SportsHandball
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.ui.Formatting
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.theme.AppColors
import com.discflightschool.app.video.VideoSurface
import com.discflightschool.app.video.rememberPlaybackState
import com.discflightschool.app.video.rememberVideoPlayer
import com.discflightschool.core.baseline.ProBaselineDatabase

/**
 * Marks which frame each throw phase happens on, before analysis runs.
 *
 * Scoring against pro data snaps every frame to its nearest phase. Without
 * these marks the phases are assumed to fall at fixed fractions of the clip,
 * which is close enough to look reasonable and wrong enough to compare a
 * reach-back against a release.
 */
@Composable
fun PhaseFrameSelectorScreen(onBack: () -> Unit, onAnalyze: () -> Unit) {
    val container = LocalAppContainer.current
    val workbench = container.workbench
    val videoPath = workbench.formVideoPath

    if (videoPath == null) {
        Scaffold(topBar = { AppTopBar(title = "Select phase frames", onBack = onBack) }) { padding ->
            com.discflightschool.app.ui.components.LoadingState(
                "No video selected",
                Modifier.padding(padding),
            )
        }
        return
    }

    val startMs = workbench.analysisStartMs
    val endMs = workbench.analysisEndMs
    val phases = ProBaselineDatabase.phaseNames(workbench.throwType)

    val player = rememberVideoPlayer(videoPath)
    val playback = rememberPlaybackState(player)
    val marks = remember { mutableStateMapOf<String, Long>() }

    LaunchedEffect(videoPath) { player.seekTo(startMs) }

    // Playback stops at the end of the trimmed range: everything outside it is
    // walk-up and celebration, and scrubbing past it only loses the throw.
    LaunchedEffect(playback.positionMs) {
        if (playback.positionMs >= endMs) {
            player.pause()
            player.seekTo(endMs)
        }
    }

    fun step(deltaMs: Long) {
        player.pause()
        player.seekTo((playback.positionMs + deltaMs).coerceIn(startMs, endMs))
    }

    val allMarked = phases.all { it in marks }

    Scaffold(
        topBar = {
            AppTopBar(title = "Select phase frames", onBack = onBack) {
                TextButton(
                    onClick = {
                        workbench.phaseFrameIndices = marks.mapValues { (_, timestampMs) ->
                            frameIndexFor(timestampMs, startMs)
                        }
                        onAnalyze()
                    },
                    enabled = allMarked,
                ) {
                    Text("Analyze")
                }
            }
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize(),
        ) {
            Box(
                modifier = Modifier
                    .weight(5f)
                    .fillMaxWidth()
                    .background(Color.Black),
                contentAlignment = Alignment.Center,
            ) {
                VideoSurface(player, Modifier.fillMaxSize())
            }

            Column(
                modifier = Modifier
                    .background(Color.Black.copy(alpha = 0.85f))
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(onClick = { step(-COARSE_SKIP_MS) }) {
                        Icon(
                            Icons.Default.FastRewind,
                            contentDescription = "Back half a second",
                            tint = AppColors.Muted,
                        )
                    }
                    IconButton(onClick = { step(-FRAME_STEP_MS) }) {
                        Icon(
                            Icons.Default.SkipPrevious,
                            contentDescription = "Back one frame",
                            tint = Color.White,
                        )
                    }
                    IconButton(
                        onClick = { if (playback.isPlaying) player.pause() else player.play() },
                    ) {
                        Icon(
                            if (playback.isPlaying) {
                                Icons.Default.PauseCircle
                            } else {
                                Icons.Default.PlayCircle
                            },
                            contentDescription = if (playback.isPlaying) "Pause" else "Play",
                            tint = Color.White,
                            modifier = Modifier.size(36.dp),
                        )
                    }
                    IconButton(onClick = { step(FRAME_STEP_MS) }) {
                        Icon(
                            Icons.Default.SkipNext,
                            contentDescription = "Forward one frame",
                            tint = Color.White,
                        )
                    }
                    IconButton(onClick = { step(COARSE_SKIP_MS) }) {
                        Icon(
                            Icons.Default.FastForward,
                            contentDescription = "Forward half a second",
                            tint = AppColors.Muted,
                        )
                    }
                    Spacer(Modifier.width(8.dp))
                    Text(
                        seconds(playback.positionMs.coerceIn(startMs, endMs)),
                        color = Color.White,
                        style = MaterialTheme.typography.labelMedium,
                    )
                }

                val span = (endMs - startMs).coerceAtLeast(1)
                Slider(
                    value = (playback.positionMs - startMs).coerceIn(0, span).toFloat(),
                    onValueChange = { player.seekTo(startMs + it.toLong()) },
                    valueRange = 0f..span.toFloat(),
                )
            }

            Text(
                "Step frame by frame, then tap a phase card to mark it.",
                modifier = Modifier
                    .fillMaxWidth()
                    .background(AppColors.Surface)
                    .padding(horizontal = 16.dp, vertical = 6.dp),
                style = MaterialTheme.typography.labelMedium,
                color = AppColors.Muted,
                textAlign = TextAlign.Center,
            )

            LazyVerticalGrid(
                columns = GridCells.Fixed(2),
                modifier = Modifier.weight(4f),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(phases.size) { index ->
                    val phase = phases[index]
                    PhaseCard(
                        phase = phase,
                        markedAtMs = marks[phase],
                        onMark = {
                            marks[phase] = playback.positionMs.coerceIn(startMs, endMs)
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun PhaseCard(phase: String, markedAtMs: Long?, onMark: () -> Unit) {
    val isSet = markedAtMs != null
    val accent = if (isSet) AppColors.Good else AppColors.Muted

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(
                if (isSet) AppColors.Good.copy(alpha = 0.16f) else AppColors.Surface,
                RoundedCornerShape(8.dp),
            )
            .border(
                width = if (isSet) 1.5.dp else 1.dp,
                color = accent,
                shape = RoundedCornerShape(8.dp),
            )
            .clickable(onClick = onMark)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            phaseIcon(phase),
            contentDescription = null,
            tint = accent,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text(
                Formatting.phaseLabel(phase),
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Bold,
                color = if (isSet) AppColors.OnSurface else AppColors.Muted,
            )
            Text(
                if (markedAtMs != null) seconds(markedAtMs) else "Tap to mark",
                style = MaterialTheme.typography.labelSmall,
                color = accent,
            )
        }
        if (isSet) {
            Icon(
                Icons.Default.CheckCircle,
                contentDescription = null,
                tint = AppColors.Good,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

internal fun phaseIcon(phase: String): ImageVector = when (phase) {
    "reach_back" -> Icons.AutoMirrored.Filled.ArrowBack
    "power_pocket" -> Icons.Default.SportsHandball
    "release" -> Icons.Default.RocketLaunch
    "follow_through" -> Icons.AutoMirrored.Filled.Redo
    "wind_up" -> Icons.Default.RotateRight
    else -> Icons.Default.Flag
}

/**
 * The analysis frame a timestamp falls on.
 *
 * Analysis samples one frame every [com.discflightschool.app.video.FrameExtractor.POSE_INTERVAL_MS]
 * from the trim start, so this is the index into that sampled sequence — not a
 * frame number in the source file.
 */
internal fun frameIndexFor(timestampMs: Long, analysisStartMs: Long): Int =
    ((timestampMs - analysisStartMs) /
        com.discflightschool.app.video.FrameExtractor.POSE_INTERVAL_MS).toInt()
        .coerceAtLeast(0)

private fun seconds(millis: Long) = "${Formatting.decimal(millis / 1000.0)}s"

/** One frame at 30fps — the smallest useful step for picking a phase. */
private const val FRAME_STEP_MS = 33L

/** A coarse skip, for getting to the right part of the clip quickly. */
private const val COARSE_SKIP_MS = 500L
