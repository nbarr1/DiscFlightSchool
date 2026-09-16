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
import android.os.Handler
import android.os.Looper
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
import androidx.media3.transformer.ProgressHolder
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
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

/**
 * Burns the flight path into a copy of the clip.
 *
 * The trail is redrawn only when the export crosses into a new tracked frame,
 * so the path draws on as the disc flies rather than appearing all at once. It
 * renders into one of two reusable bitmaps rather than into one image per
 * tracked frame: at 1080p a full-frame ARGB bitmap is about 8 MB, so holding
 * ninety of them would cost most of a gigabyte and end the export in an
 * OutOfMemoryError before the encoder ever ran.
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
    ): File {
        require(result.detections.isNotEmpty()) { "Nothing to draw: the flight path is empty" }

        val output = withContext(Dispatchers.IO) {
            val dimensions = FrameExtractor().dimensions(videoPath) ?: (1080 to 1920)
            outputDir.mkdirs()
            Triple(
                dimensions.first,
                dimensions.second,
                File(outputDir, "flight_path_${System.currentTimeMillis()}.mp4"),
            )
        }
        val (width, height, file) = output

        val frames = result.detections.map { it.frameIndex }.distinct().sorted()
        val overlay = TrailOverlay(
            result = result,
            frames = sampleFrames(frames, MAX_OVERLAY_FRAMES),
            anchors = anchors,
            width = width,
            height = height,
        )

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
                        OverlayEffect(ImmutableList.of<TextureOverlay>(overlay)),
                    ),
                ),
            )
            .build()

        try {
            // Transformer is bound to the looper of the thread that builds it
            // and rejects calls from anywhere else, so it is built, started and
            // cancelled on the main thread. The frame work it schedules runs on
            // its own threads regardless.
            withContext(Dispatchers.Main) {
                runTransformer(editedMediaItem, file, onProgress)
            }
        } finally {
            overlay.release()
        }

        onProgress?.invoke(1f)
        return file
    }

    private suspend fun runTransformer(
        editedMediaItem: EditedMediaItem,
        output: File,
        onProgress: ((Float) -> Unit)?,
    ): ExportResult = coroutineScope {
        val transformer = Transformer.Builder(context).build()

        val progressJob = launch {
            val holder = ProgressHolder()
            while (isActive) {
                delay(PROGRESS_POLL_MS)
                if (transformer.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) {
                    onProgress?.invoke(holder.progress / 100f)
                }
            }
        }

        try {
            suspendCancellableCoroutine { continuation ->
                transformer.addListener(
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

                continuation.invokeOnCancellation {
                    // Cancellation can arrive on any thread; the transformer
                    // only accepts its own.
                    Handler(Looper.getMainLooper()).post {
                        runCatching { transformer.cancel() }
                    }
                }

                transformer.start(editedMediaItem, output.absolutePath)
            }
        } finally {
            progressJob.cancel()
        }
    }

    /**
     * The trail as of whatever tracked frame the export has reached.
     *
     * Two bitmaps rather than one: the overlay is uploaded to a texture when
     * the returned instance changes, so handing back the same object after
     * drawing into it would leave the previous image on screen. Alternating
     * means the buffer being redrawn is never the one just uploaded.
     */
    private class TrailOverlay(
        private val result: FlightTrackingResult,
        private val frames: List<Int>,
        private val anchors: List<WorldAnchorFrame>,
        private val width: Int,
        private val height: Int,
    ) : BitmapOverlay() {

        private val buffers = Array(2) {
            Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        }
        private var bufferIndex = 0
        private var renderedFrame: Int? = null
        private var rendered = false

        override fun getBitmap(presentationTimeUs: Long): Bitmap {
            // Null until the export reaches the first tracked frame, which
            // leaves the footage before the throw clean rather than showing the
            // start of the path over it.
            val frame = frames.lastOrNull { frameStartUs(it) <= presentationTimeUs }

            if (rendered && frame == renderedFrame) return buffers[bufferIndex]

            bufferIndex = (bufferIndex + 1) % buffers.size
            val target = buffers[bufferIndex]
            target.eraseColor(Color.TRANSPARENT)
            if (frame != null) {
                drawTrail(
                    canvas = Canvas(target),
                    currentFrame = frame,
                    showDisc = frame == frames.lastOrNull(),
                )
            }
            renderedFrame = frame
            rendered = true
            return target
        }

        // The effect pipeline releases its overlays on teardown, and the export
        // releases this one when it finishes, whichever comes first. Recycling
        // an already-recycled bitmap is a no-op, so both paths are safe.
        override fun release() {
            super.release()
            buffers.forEach { it.recycle() }
        }

        private fun frameStartUs(frame: Int): Long =
            (result.detectionAtFrame(frame)?.timestampMs ?: 0L) * 1000

        /**
         * Draw the trail up to [currentFrame].
         *
         * Deliberately plain `android.graphics`: this runs off the composition,
         * and the export must not depend on a Compose draw scope existing.
         */
        private fun drawTrail(canvas: Canvas, currentFrame: Int, showDisc: Boolean) {
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
            if (points.isEmpty()) return

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
                val detection = result.detectionAtFrame(currentFrame) ?: return
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
    }

    companion object {
        /**
         * The cap on trail updates, about nine seconds at the tracking rate.
         * Beyond this the extra redraws stop being worth the smoothness they
         * add, so tracked frames are sampled evenly instead.
         */
        const val MAX_OVERLAY_FRAMES = 90

        /** How often the export's progress is read back, in milliseconds. */
        private const val PROGRESS_POLL_MS = 250L

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
