package com.discflightschool.app.video

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.util.Log
import com.discflightschool.core.detection.ExtractedFrame
import com.discflightschool.core.detection.FrameSampling
import java.io.File
import java.io.FileOutputStream
import kotlin.math.roundToInt
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/**
 * Decodes frames out of a clip at a fixed rate.
 *
 * Frame index 0 is the first frame at or after the trim start, never the start
 * of the file. Everything downstream — tracker seed points, the player's own
 * frame counter, collected training labels — is indexed in that space, so an
 * extractor that ignored the trim would pair every position with an image from
 * the wrong moment.
 *
 * Seeks use `OPTION_CLOSEST`, which decodes to the requested time rather than
 * snapping to the nearest keyframe. Snapping is much faster and completely
 * wrong here: it would shift frames by up to a second while still producing
 * plausible-looking images.
 */
class FrameExtractor(private val io: CoroutineDispatcher = Dispatchers.IO) {

    /** The working width frames are downscaled to before inference. */
    val workingWidth: Int = DEFAULT_WORKING_WIDTH

    /**
     * Extract up to [maxFrames] frames at [fps] into [outputDir], returning
     * those that made it to disk.
     *
     * A frame the decoder cannot produce is skipped rather than aborting the
     * run: the list is allowed to be sparse, which is exactly why
     * [ExtractedFrame] carries its index explicitly.
     */
    suspend fun extractFrames(
        videoPath: String,
        outputDir: File,
        fps: Double,
        maxFrames: Int,
        startMs: Long = 0,
        endMs: Long? = null,
        onProgress: ((Float) -> Unit)? = null,
    ): List<ExtractedFrame> = withContext(io) {
        outputDir.mkdirs()

        val retriever = MediaMetadataRetriever()
        val frames = ArrayList<ExtractedFrame>()

        try {
            retriever.setDataSource(videoPath)
            val durationMs = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()

            val timestamps = FrameSampling.sampleTimestamps(
                fps = fps,
                maxFrames = maxFrames,
                startMs = startMs,
                endMs = endMs,
                durationMs = durationMs,
            )

            val targetHeight = targetHeightFor(retriever)

            for ((index, timestampMs) in timestamps.withIndex()) {
                currentCoroutineContext().ensureActive()

                val bitmap = frameAt(retriever, timestampMs, targetHeight) ?: continue
                val file = File(outputDir, "frame_%04d.jpg".format(index))
                val written = runCatching {
                    FileOutputStream(file).use { out ->
                        bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
                    }
                }.getOrElse {
                    Log.w(TAG, "Failed to write frame $index", it)
                    false
                }
                bitmap.recycle()

                if (written) frames += ExtractedFrame(index = index, path = file.absolutePath)
                onProgress?.invoke((index + 1).toFloat() / timestamps.size)
            }
        } catch (e: Exception) {
            if (frames.isEmpty()) {
                Log.w(TAG, "Frame extraction failed with no output", e)
            } else {
                Log.w(TAG, "Frame extraction ended early (${frames.size} salvaged)", e)
            }
        } finally {
            runCatching { retriever.release() }
        }

        frames
    }

    /** A single frame as a bitmap, downscaled to the working resolution. */
    suspend fun frameBitmapAt(videoPath: String, timestampMs: Long): Bitmap? = withContext(io) {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(videoPath)
            frameAt(retriever, timestampMs, targetHeightFor(retriever))
        } catch (e: Exception) {
            Log.w(TAG, "Could not read a frame at ${timestampMs}ms", e)
            null
        } finally {
            runCatching { retriever.release() }
        }
    }

    /** Clip duration in milliseconds, or null when it cannot be read. */
    suspend fun durationMs(videoPath: String): Long? = withContext(io) {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(videoPath)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
        } catch (e: Exception) {
            Log.w(TAG, "Could not read the duration of $videoPath", e)
            null
        } finally {
            runCatching { retriever.release() }
        }
    }

    /** The clip's display dimensions, accounting for its rotation metadata. */
    suspend fun dimensions(videoPath: String): Pair<Int, Int>? = withContext(io) {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(videoPath)
            val width = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()
            val height = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
            val rotation = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                ?.toIntOrNull() ?: 0
            if (width == null || height == null) {
                null
            } else if (rotation == 90 || rotation == 270) {
                height to width
            } else {
                width to height
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not read the dimensions of $videoPath", e)
            null
        } finally {
            runCatching { retriever.release() }
        }
    }

    private fun frameAt(
        retriever: MediaMetadataRetriever,
        timestampMs: Long,
        targetHeight: Int?,
    ): Bitmap? {
        val timeUs = timestampMs * 1000
        return runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1 && targetHeight != null) {
                retriever.getScaledFrameAtTime(
                    timeUs,
                    MediaMetadataRetriever.OPTION_CLOSEST,
                    workingWidth,
                    targetHeight,
                )
            } else {
                retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST)
                    ?.let { scaleToWorkingWidth(it) }
            }
        }.getOrNull()
    }

    /**
     * The height that preserves the clip's aspect ratio at [workingWidth], or
     * null when the source is already narrower and should not be upscaled.
     */
    private fun targetHeightFor(retriever: MediaMetadataRetriever): Int? {
        val width = retriever
            .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()
            ?: return null
        val height = retriever
            .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
            ?: return null
        if (width <= workingWidth) return null
        return (height * workingWidth.toDouble() / width).roundToInt().coerceAtLeast(2)
    }

    private fun scaleToWorkingWidth(bitmap: Bitmap): Bitmap {
        if (bitmap.width <= workingWidth) return bitmap
        val height = (bitmap.height * workingWidth.toDouble() / bitmap.width)
            .roundToInt()
            .coerceAtLeast(2)
        val scaled = Bitmap.createScaledBitmap(bitmap, workingWidth, height, true)
        if (scaled !== bitmap) bitmap.recycle()
        return scaled
    }

    companion object {
        private const val TAG = "FrameExtractor"

        /**
         * Frames are decoded at 640px wide. Per-frame inference cost scales with
         * input area, and the detector's own input is 640 square, so anything
         * larger is thrown away immediately afterwards.
         */
        const val DEFAULT_WORKING_WIDTH = 640

        private const val JPEG_QUALITY = 85

        /** The sampling rate the detection pipeline runs at. */
        const val DETECTION_FPS = 10.0

        /** The interval pose analysis samples frames at. */
        const val POSE_INTERVAL_MS = 50L
    }
}
