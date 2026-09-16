package com.discflightschool.app.video

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Shader
import androidx.annotation.OptIn
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.TextureOverlay
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import com.discflightschool.core.detection.FlightTrackingResult
import com.discflightschool.core.tracking.WorldAnchorFrame
import com.discflightschool.core.tracking.WorldLock
import com.google.common.collect.ImmutableList
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

/**
 * Burns the flight path into a copy of the clip.
 *
 * The trail is pre-rendered once per tracked frame and then selected by
 * presentation time during the export, so the path draws on as the disc flies
 * rather than appearing all at once. Rendering inside the frame callback
 * instead would put path construction on the encoder's critical path for every
 * frame of the video, including the ones with no new detection.
 */
@OptIn(UnstableApi::class)
class FlightVideoExporter(private val context: Context) {

    /**
     * Export [videoPath] with [result] drawn over it, returning the output file.
     *
     * [trimStartMs] and [trimEndMs] clip the export to the tracked range, which
     * is also the range the frame indices are relative to.
     */
    suspend fun export(
        videoPath: String,
        result: FlightTrackingResult,
        trimStartMs: Long,
        trimEndMs: Long?,
        anchors: List<WorldAnchorFrame>,
        outputDir: File,
        onProgress: ((Float) -> Unit)? = null,
    ): File = withContext(Dispatchers.IO) {
        require(result.detections.isNotEmpty()) { "Nothing to draw: the flight path is empty" }

        val dimensions = FrameExtractor().dimensions(videoPath) ?: (1080 to 1920)
        val width = dimensions.first
        val height = dimensions.second

        val frames = result.detections.map { it.frameIndex }.distinct().sorted()
        val sampled = sampleFrames(frames, MAX_OVERLAY_FRAMES)

        // Pre-render one trail image per sampled frame.
        val overlays = ArrayList<TimedOverlay>(sampled.size)
        for ((index, frame) in sampled.withIndex()) {
            val detection = result.detectionAtFrame(frame) ?: continue
            val bitmap = renderTrail(
                result = result,
                currentFrame = frame,
                width = width,
                height = height,
                anchors = anchors,
                showDisc = index == sampled.lastIndex,
            )
            overlays += TimedOverlay(
                startUs = detection.timestampMs * 1000,
                bitmap = bitmap,
            )
            onProgress?.invoke((index + 1).toFloat() / sampled.size * 0.6f)
        }
        check(overlays.isNotEmpty()) { "No overlay frames could be rendered" }

        val mediaItem = MediaItem.Builder()
            .setUri(File(videoPath).toURI().toString())
            .apply {
                if (trimEndMs != null) {
                    setClippingConfiguration(
                        MediaItem.ClippingConfiguration.Builder()
                            .setStartPositionMs(trimStartMs)
                            .setEndPositionMs(trimEndMs)
                            .build(),
                    )
                }
            }
            .build()

        val editedMediaItem = EditedMediaItem.Builder(mediaItem)
            .setEffects(
                Effects(
                    /* audioProcessors = */ ImmutableList.of(),
                    /* videoEffects = */ ImmutableList.of<Effect>(
                        OverlayEffect(ImmutableList.of<TextureOverlay>(TrailOverlay(overlays))),
                    ),
                ),
            )
            .build()

        outputDir.mkdirs()
        val output = File(outputDir, "flight_path_${System.currentTimeMillis()}.mp4")

        try {
            runTransformer(editedMediaItem, output)
            onProgress?.invoke(1f)
            output
        } finally {
            overlays.forEach { it.bitmap.recycle() }
        }
    }

    private suspend fun runTransformer(
        editedMediaItem: EditedMediaItem,
        output: File,
    ): ExportResult = suspendCancellableCoroutine { continuation ->
        // Transformer must be built and started on a thread with a Looper.
        val transformer = Transformer.Builder(context)
            .addListener(
                object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, result: ExportResult) {
                        if (continuation.isActive) continuation.resume(result)
                    }

                    override fun onError(
                        composition: Composition,
                        result: ExportResult,
                        exception: ExportException,
                    ) {
                        if (continuation.isActive) continuation.resumeWithException(exception)
                    }
                },
            )
            .build()

        continuation.invokeOnCancellation { transformer.cancel() }
        transformer.start(editedMediaItem, output.absolutePath)
    }

    /** One pre-rendered trail image and the time it becomes current. */
    private class TimedOverlay(val startUs: Long, val bitmap: Bitmap)

    /**
     * Picks the newest pre-rendered trail at or before the current time.
     *
     * Each image already contains the whole path up to its own frame, so
     * holding one until the next is due produces the draw-on animation.
     */
    private class TrailOverlay(private val overlays: List<TimedOverlay>) : BitmapOverlay() {
        override fun getBitmap(presentationTimeUs: Long): Bitmap {
            var chosen = overlays.first()
            for (overlay in overlays) {
                if (overlay.startUs <= presentationTimeUs) chosen = overlay else break
            }
            return chosen.bitmap
        }
    }

    /**
     * Draw the trail up to [currentFrame] onto a transparent bitmap.
     *
     * Deliberately plain `android.graphics`: this runs off the composition, and
     * the export must not depend on a Compose draw scope existing.
     */
    private fun renderTrail(
        result: FlightTrackingResult,
        currentFrame: Int,
        width: Int,
        height: Int,
        anchors: List<WorldAnchorFrame>,
        showDisc: Boolean,
    ): Bitmap {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)

        val points = result.detectionsUpToFrame(currentFrame).map { detection ->
            val position = WorldLock.toCanvas(
                detection = detection,
                currentFrame = currentFrame,
                width = width.toDouble(),
                height = height.toDouble(),
                anchors = anchors,
            )
            position.x.toFloat() to position.y.toFloat()
        }
        if (points.isEmpty()) return bitmap

        if (points.size >= 2) {
            val path = Path().apply {
                moveTo(points[0].first, points[0].second)
                for (i in 0 until points.size - 1) {
                    val midX = (points[i].first + points[i + 1].first) / 2
                    val midY = (points[i].second + points[i + 1].second) / 2
                    quadTo(points[i].first, points[i].second, midX, midY)
                }
                lineTo(points.last().first, points.last().second)
            }

            val gradient = LinearGradient(
                points.first().first,
                points.first().second,
                points.last().first,
                points.last().second,
                intArrayOf(TRAIL_START, TRAIL_MIDDLE, TRAIL_END),
                null,
                Shader.TileMode.CLAMP,
            )

            val glow = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = width * 0.013f
                strokeCap = Paint.Cap.ROUND
                strokeJoin = Paint.Join.ROUND
                shader = gradient
                alpha = 55
                maskFilter = BlurMaskFilter(width * 0.007f, BlurMaskFilter.Blur.NORMAL)
            }
            canvas.drawPath(path, glow)

            val line = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = width * 0.004f
                strokeCap = Paint.Cap.ROUND
                strokeJoin = Paint.Join.ROUND
                shader = gradient
                alpha = 230
            }
            canvas.drawPath(path, line)
        }

        if (showDisc) {
            val detection = result.detectionAtFrame(currentFrame)
            if (detection != null) {
                val centerX = (detection.x * width).toFloat()
                val centerY = (detection.y * height).toFloat()
                val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    style = Paint.Style.STROKE
                    color = Color.WHITE
                    strokeWidth = width * 0.003f
                }
                canvas.drawCircle(centerX, centerY, width * 0.012f, ring)
                canvas.drawCircle(
                    centerX,
                    centerY,
                    width * 0.005f,
                    Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE },
                )
            }
        }

        return bitmap
    }

    companion object {
        /**
         * The cap on pre-rendered overlays, about nine seconds at the tracking
         * rate. Beyond this the render time stops being worth the extra
         * smoothness, so frames are sampled evenly instead.
         */
        const val MAX_OVERLAY_FRAMES = 90

        private val TRAIL_START = Color.parseColor("#FF1AF01A")
        private val TRAIL_MIDDLE = Color.parseColor("#FFF0F01A")
        private val TRAIL_END = Color.parseColor("#FFF01A1A")

        /** Evenly sample [frames] down to [max], always keeping both ends. */
        fun sampleFrames(frames: List<Int>, max: Int): List<Int> {
            if (frames.size <= max) return frames
            val step = (frames.size - 1).toDouble() / (max - 1)
            return (0 until max)
                .map { frames[(it * step).roundToInt().coerceIn(0, frames.size - 1)] }
                .distinct()
        }
    }
}
