package com.discflightschool.app.video

import androidx.annotation.OptIn
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import java.io.File
import kotlinx.coroutines.delay

/**
 * An [ExoPlayer] bound to the composition, released when it leaves.
 *
 * Frame-accurate seeking is on: every screen that uses this scrubs to a
 * specific frame, and the default nearest-keyframe seek would show an image
 * from up to a second away from the position the overlay is drawn for.
 */
@OptIn(UnstableApi::class)
@Composable
fun rememberVideoPlayer(videoPath: String, playWhenReady: Boolean = false): ExoPlayer {
    val context = LocalContext.current
    val player = remember(videoPath) {
        ExoPlayer.Builder(context)
            .setSeekParameters(androidx.media3.exoplayer.SeekParameters.EXACT)
            .build()
            .apply {
                setMediaItem(MediaItem.fromUri(File(videoPath).toURI().toString()))
                prepare()
                this.playWhenReady = playWhenReady
            }
    }

    DisposableEffect(player) {
        onDispose { player.release() }
    }

    return player
}

/** The player's live position, duration, and play state, polled for the UI. */
data class PlaybackState(
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val isPlaying: Boolean = false,
    val isReady: Boolean = false,
)

/**
 * Polls [player] for its position.
 *
 * ExoPlayer has no position callback — [Player.Listener] reports state changes
 * and discontinuities, not the steady advance of playback — so a scrubber that
 * tracks the video has to sample it.
 */
@Composable
fun rememberPlaybackState(player: ExoPlayer, pollMs: Long = 33): PlaybackState {
    var state by remember(player) { mutableStateOf(PlaybackState()) }
    var duration by remember(player) { mutableLongStateOf(0L) }

    DisposableEffect(player) {
        val listener = object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_READY) {
                    duration = player.duration.coerceAtLeast(0L)
                }
            }
        }
        player.addListener(listener)
        onDispose { player.removeListener(listener) }
    }

    LaunchedEffect(player) {
        while (true) {
            val known = player.duration.takeIf { it > 0 } ?: duration
            state = PlaybackState(
                positionMs = player.currentPosition.coerceAtLeast(0L),
                durationMs = known.coerceAtLeast(0L),
                isPlaying = player.isPlaying,
                isReady = player.playbackState == Player.STATE_READY,
            )
            delay(pollMs)
        }
    }

    return state
}

/**
 * The clip's display aspect ratio, or null until the first frame is decoded.
 *
 * Read from the player rather than from the file's stored dimensions so that
 * the pixel aspect ratio of anamorphic footage is included — the same number
 * [PlayerView] fits the image with.
 */
@Composable
fun rememberVideoAspectRatio(player: ExoPlayer): Float? {
    var ratio by remember(player) { mutableFloatStateOf(0f) }

    DisposableEffect(player) {
        val listener = object : Player.Listener {
            override fun onVideoSizeChanged(videoSize: VideoSize) {
                val width = videoSize.width * videoSize.pixelWidthHeightRatio
                val height = videoSize.height.toFloat()
                ratio = if (width > 0f && height > 0f) width / height else 0f
            }
        }
        player.addListener(listener)
        onDispose { player.removeListener(listener) }
    }

    return ratio.takeIf { it > 0f }
}

/**
 * The video, letterboxed inside [modifier], with [content] drawn over exactly
 * the image and nothing else.
 *
 * Overlays and taps have to share the video's coordinate space: a skeleton or a
 * flight path is stored in normalized 0-1 image coordinates, and a tap is read
 * back the same way. Drawing them over the full parent instead would stretch
 * every position into the letterbox bars whenever the clip's aspect ratio
 * differs from the space on screen, and would map taps to the wrong pixel.
 */
@Composable
fun VideoStage(
    player: ExoPlayer,
    modifier: Modifier = Modifier,
    content: @Composable BoxScope.() -> Unit = {},
) {
    val aspectRatio = rememberVideoAspectRatio(player)

    Box(
        modifier = modifier.background(Color.Black),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            // Before the first frame the ratio is unknown; filling the parent
            // keeps the surface attached so decoding can start.
            modifier = if (aspectRatio != null) {
                Modifier.aspectRatio(aspectRatio)
            } else {
                Modifier.fillMaxSize()
            },
        ) {
            VideoSurface(player, Modifier.fillMaxSize())
            content()
        }
    }
}

/** The video surface itself, with no built-in controls. */
@OptIn(UnstableApi::class)
@Composable
fun VideoSurface(player: ExoPlayer, modifier: Modifier = Modifier) {
    AndroidView(
        modifier = modifier,
        factory = { context ->
            PlayerView(context).apply {
                this.player = player
                useController = false
                // FIT, never FILL: filling would stretch a clip whose aspect
                // ratio differs from the space it is given. Overlays keep the
                // video's coordinates by living inside [VideoStage], which
                // sizes the surface to the image instead.
                resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                setShutterBackgroundColor(android.graphics.Color.TRANSPARENT)
            }
        },
        update = { view -> view.player = player },
    )
}
