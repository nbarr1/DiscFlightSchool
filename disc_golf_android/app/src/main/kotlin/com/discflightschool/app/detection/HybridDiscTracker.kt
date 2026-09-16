package com.discflightschool.app.detection

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.util.Log
import com.discflightschool.app.video.FrameExtractor
import com.discflightschool.core.detection.DiscDetection
import com.discflightschool.core.detection.FlightTrackingResult
import com.discflightschool.core.detection.Trajectory
import com.discflightschool.core.geometry.Vec2
import com.discflightschool.core.math.AngleCalculator
import com.discflightschool.core.tracking.DiscTracker
import com.discflightschool.core.tracking.TrackerSeedPoint
import com.discflightschool.core.tracking.TrackerSession
import java.io.File
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Detection-refined tracking: a spline through the user's seed points, then a
 * per-frame search for the disc near each predicted position.
 *
 * The spline is the track here, not a hint. Where the detector offers several
 * candidates, the one closest to the prediction wins rather than the most
 * confident one — the user placed those seeds, and a stray high-confidence blob
 * elsewhere in the window must not hijack the path they are correcting.
 */
class HybridDiscTracker(
    private val detector: DiscDetector,
    private val frameExtractor: FrameExtractor,
    private val cacheDir: File,
    /** Optional disc colour, which adds blob matching alongside the detector. */
    private val discColor: Int? = null,
) : DiscTracker {

    override var progress: Double = 0.0
        private set

    override var statusMessage: String = ""
        private set

    /**
     * Whether the most recent run had the detector model available.
     *
     * False means refinement fell back to colour-blob matching alone, which is
     * materially less accurate. Callers should surface that rather than let it
     * pass as an ordinary result.
     */
    var usedDetectorModel: Boolean = false
        private set

    override suspend fun track(
        session: TrackerSession,
        seedPoints: List<TrackerSeedPoint>,
    ): FlightTrackingResult = withContext(Dispatchers.Default) {
        require(seedPoints.size >= 3) {
            "HybridDiscTracker needs at least 3 seed points, got ${seedPoints.size}"
        }
        require(session.fps > 0) { "fps must be greater than zero" }
        require(session.totalFrames > 0) { "totalFrames must be greater than zero" }

        progress = 0.0
        statusMessage = "Generating spline prediction..."

        val anchors = LinkedHashMap<Int, Vec2>()
        for (seed in seedPoints) {
            require(seed.frameIndex in 0 until session.totalFrames) {
                "seed frame ${seed.frameIndex} is outside 0..${session.totalFrames - 1}"
            }
            anchors[seed.frameIndex] = Vec2(seed.x.coerceIn(0.0, 1.0), seed.y.coerceIn(0.0, 1.0))
        }
        require(anchors.size >= 3) { "Need at least 3 unique seed frames" }

        val sortedKeys = anchors.keys.sorted()
        val firstFrame = sortedKeys.first()
        val lastFrame = sortedKeys.last()
        val predicted = AngleCalculator.interpolateAnchors(anchors)

        progress = 0.1
        statusMessage = "Extracting video frames..."

        val framesDir = File(cacheDir, "hybrid_detect_${System.currentTimeMillis()}")
        try {
            val extracted = frameExtractor.extractFrames(
                videoPath = session.videoPath,
                outputDir = framesDir,
                fps = session.fps,
                maxFrames = session.totalFrames,
                startMs = session.trimStartMs,
                endMs = session.trimEndMs,
            )
            if (extracted.isEmpty()) error("No frames could be extracted")

            // Index by video frame number rather than list position: extraction
            // can skip a frame, and looking up by position would pair each
            // spline prediction with the wrong image from that point on.
            val framesByIndex = extracted.associate { it.index to it.path }

            progress = 0.3
            statusMessage = "Refining with detection..."

            // Load the detector up front. Nothing else in the app loads it
            // during a normal run, so without this a fresh install would
            // silently refine against colour blobs alone.
            runCatching { detector.loadModel() }.onFailure {
                Log.w(TAG, "Hybrid refinement running without the detector model", it)
            }
            usedDetectorModel = detector.isModelLoaded.value

            val targetHsv = discColor?.let { color ->
                FloatArray(3).also {
                    Color.RGBToHSV(Color.red(color), Color.green(color), Color.blue(color), it)
                }
            }

            val refined = ArrayList<DiscDetection>()
            val frameCount = lastFrame - firstFrame + 1

            for (frame in firstFrame..lastFrame) {
                progress = 0.3 + (frame - firstFrame).toDouble() / frameCount * 0.6
                if (frame % 10 == 0) {
                    statusMessage = "Refining frame ${frame - firstFrame + 1}/$frameCount"
                }

                val splinePos = predicted[frame] ?: continue
                var position = splinePos
                var confidence = SPLINE_ONLY_CONFIDENCE

                val bitmap = framesByIndex[frame]?.let { path ->
                    runCatching { BitmapFactory.decodeFile(path) }.getOrNull()
                }

                if (bitmap != null) {
                    val colorResult = targetHsv?.let { findColorBlob(bitmap, splinePos, it) }
                    val yoloResult = if (detector.isModelLoaded.value) {
                        detector.detectInWindow(
                            bitmap = bitmap,
                            frameIndex = frame,
                            fps = session.fps,
                            centerX = splinePos.x,
                            centerY = splinePos.y,
                            regionSize = WINDOW_FRACTION * 2,
                        ).let { candidates ->
                            when {
                                candidates.isEmpty() -> null
                                candidates.size == 1 -> candidates.first()
                                else -> Trajectory.selectClosestCandidate(
                                    candidates,
                                    splinePos.x,
                                    splinePos.y,
                                )
                            }
                        }?.let { Vec2(it.x, it.y) }
                    } else {
                        null
                    }

                    when {
                        colorResult != null && yoloResult != null -> {
                            if (colorResult.distanceTo(yoloResult) < AGREEMENT_DISTANCE) {
                                // Both agree: average the positions and trust it.
                                position = Vec2(
                                    (colorResult.x + yoloResult.x) / 2,
                                    (colorResult.y + yoloResult.y) / 2,
                                )
                                confidence = AGREEMENT_CONFIDENCE
                            } else {
                                // They disagree: prefer the trained model.
                                position = yoloResult
                                confidence = MODEL_CONFIDENCE
                            }
                        }
                        colorResult != null -> {
                            position = colorResult
                            confidence = COLOR_CONFIDENCE
                        }
                        yoloResult != null -> {
                            position = yoloResult
                            confidence = MODEL_CONFIDENCE
                        }
                    }

                    bitmap.recycle()
                }

                refined += DiscDetection(
                    frameIndex = frame,
                    x = position.x.coerceIn(0.0, 1.0),
                    y = position.y.coerceIn(0.0, 1.0),
                    width = 0.03,
                    height = 0.03,
                    confidence = confidence,
                    timestampMs = DiscDetection.timestampFor(frame, session.fps),
                )
            }

            progress = 0.95
            statusMessage = "Smoothing trajectory..."
            val smoothed = Trajectory.smoothDetections(refined, windowSize = 3)

            progress = 1.0
            statusMessage = "Complete!"

            FlightTrackingResult(
                detections = smoothed,
                videoWidth = session.videoWidth,
                videoHeight = session.videoHeight,
                fps = session.fps,
                totalFrames = session.totalFrames,
            )
        } finally {
            runCatching { framesDir.deleteRecursively() }
        }
    }

    override fun dispose() = Unit

    /**
     * The centroid of pixels matching the target colour inside the search
     * window, in normalized frame coordinates, or null when too few match.
     */
    private fun findColorBlob(bitmap: Bitmap, center: Vec2, targetHsv: FloatArray): Vec2? {
        val xMin = ((center.x - WINDOW_FRACTION) * bitmap.width).roundToInt()
            .coerceIn(0, bitmap.width - 1)
        val yMin = ((center.y - WINDOW_FRACTION) * bitmap.height).roundToInt()
            .coerceIn(0, bitmap.height - 1)
        val xMax = ((center.x + WINDOW_FRACTION) * bitmap.width).roundToInt()
            .coerceIn(0, bitmap.width - 1)
        val yMax = ((center.y + WINDOW_FRACTION) * bitmap.height).roundToInt()
            .coerceIn(0, bitmap.height - 1)

        val cropW = xMax - xMin
        val cropH = yMax - yMin
        if (cropW <= 10 || cropH <= 10) return null

        val pixels = IntArray(cropW * cropH)
        bitmap.getPixels(pixels, 0, cropW, xMin, yMin, cropW, cropH)

        var sumX = 0.0
        var sumY = 0.0
        var count = 0
        val hsv = FloatArray(3)

        for (i in pixels.indices) {
            val pixel = pixels[i]
            Color.RGBToHSV(Color.red(pixel), Color.green(pixel), Color.blue(pixel), hsv)

            // Hue is circular, so 359 and 1 are two degrees apart.
            var hueDiff = abs(hsv[0] - targetHsv[0])
            if (hueDiff > 180) hueDiff = 360 - hueDiff

            if (hueDiff <= HUE_TOLERANCE &&
                abs(hsv[1] - targetHsv[1]) <= SATURATION_TOLERANCE &&
                abs(hsv[2] - targetHsv[2]) <= VALUE_TOLERANCE
            ) {
                sumX += i % cropW
                sumY += i / cropW
                count++
            }
        }

        if (count < MIN_BLOB_PIXELS) return null

        return Vec2(
            (xMin + sumX / count) / bitmap.width,
            (yMin + sumY / count) / bitmap.height,
        )
    }

    private companion object {
        const val TAG = "HybridDiscTracker"

        /** The search window around each spline prediction, as a fraction of the frame. */
        const val WINDOW_FRACTION = 0.15

        const val SPLINE_ONLY_CONFIDENCE = 0.5
        const val COLOR_CONFIDENCE = 0.65
        const val MODEL_CONFIDENCE = 0.7
        const val AGREEMENT_CONFIDENCE = 0.9

        /** How close colour and model results must be to count as agreeing. */
        const val AGREEMENT_DISTANCE = 0.05

        const val HUE_TOLERANCE = 25.0f
        const val SATURATION_TOLERANCE = 0.3f
        const val VALUE_TOLERANCE = 0.3f
        const val MIN_BLOB_PIXELS = 5
    }
}
