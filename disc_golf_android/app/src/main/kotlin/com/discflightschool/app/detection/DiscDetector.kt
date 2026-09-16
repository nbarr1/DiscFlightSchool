package com.discflightschool.app.detection

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import com.discflightschool.app.data.AssetContent
import com.discflightschool.app.video.FrameExtractor
import com.discflightschool.core.data.DetectionSettings
import com.discflightschool.core.detection.DetectionCancelledException
import com.discflightschool.core.detection.DiscDetection
import com.discflightschool.core.detection.DiscTrack
import com.discflightschool.core.detection.FlightTrackingResult
import com.discflightschool.core.detection.Trajectory
import com.discflightschool.core.detection.YoloOutput
import com.discflightschool.core.detection.YoloPreprocessor
import com.discflightschool.core.tracking.VideoDiscDetector
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.min
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.gpu.CompatibilityList
import org.tensorflow.lite.gpu.GpuDelegate

/**
 * Finds the disc in a clip: a YOLO11 detector, plus the track-by-detection
 * state machine that turns per-frame detections into one flight path.
 *
 * Discovery scans the whole frame until the disc is found, then tracking
 * follows it in a narrow predicted window. A full-frame scan every frame costs
 * the same as the discovery scan and is far more easily distracted by a hand, a
 * second disc, or a shadow.
 *
 * App-scoped: the interpreter is expensive to build and is shared by the
 * automatic tracker, the hybrid tracker, and manual refinement. A tracker that
 * closed it would break detection for the rest of the session.
 */
class DiscDetector(
    private val context: Context,
    private val settings: DetectionSettings,
    private val frameExtractor: FrameExtractor,
    private val trainingDataDir: File,
) : VideoDiscDetector {

    private var interpreter: Interpreter? = null
    private var gpuDelegate: GpuDelegate? = null

    private var inputSize = YoloOutput.DEFAULT_INPUT_SIZE
    private var channelsFirst = false
    private var outputShape: IntArray = intArrayOf(1, 5, 8400)

    private var inputBuffer: ByteBuffer? = null
    private var outputBuffer: ByteBuffer? = null
    private var pixelBuffer: IntArray? = null
    private var floatScratch: FloatArray? = null
    private var outputScratch: FloatArray? = null

    private val loadMutex = Mutex()
    private val processMutex = Mutex()
    private val cancelRequested = AtomicBoolean(false)

    private val _isModelLoaded = MutableStateFlow(false)
    val isModelLoaded: StateFlow<Boolean> = _isModelLoaded.asStateFlow()

    private val _isProcessing = MutableStateFlow(false)
    val isProcessing: StateFlow<Boolean> = _isProcessing.asStateFlow()

    private val _progressFlow = MutableStateFlow(0.0)
    val progressFlow: StateFlow<Double> = _progressFlow.asStateFlow()

    private val _statusFlow = MutableStateFlow("")
    val statusFlow: StateFlow<String> = _statusFlow.asStateFlow()

    private val _lastResult = MutableStateFlow<FlightTrackingResult?>(null)
    val lastResult: StateFlow<FlightTrackingResult?> = _lastResult.asStateFlow()

    override val progress: Double get() = _progressFlow.value
    override val statusMessage: String get() = _statusFlow.value

    val confidenceThreshold: Double get() = settings.confidenceThreshold.value

    // ── Model loading ────────────────────────────────────────────────────

    /**
     * Load the detector, preferring a model downloaded from the training server
     * over the bundled asset.
     *
     * Building the replacement before swapping it in keeps the old interpreter
     * usable for the duration of the load, so a concurrent detection call never
     * observes a null interpreter.
     */
    override suspend fun loadModel() = loadModel(forceReload = false)

    suspend fun loadModel(forceReload: Boolean = false) {
        if (_isModelLoaded.value && !forceReload) return
        loadMutex.withLock {
            if (_isModelLoaded.value && !forceReload) return
            withContext(Dispatchers.IO) { loadModelLocked() }
        }
    }

    private fun loadModelLocked() {
        val modelBytes = downloadedModelFile()?.takeIf { it.exists() }?.let { file ->
            Log.i(TAG, "Loading the downloaded detector model: ${file.absolutePath}")
            file.readBytes()
        } ?: run {
            Log.i(TAG, "Loading the bundled detector model")
            context.assets.open(AssetContent.DETECTOR_MODEL).use { it.readBytes() }
        }

        val buffer = ByteBuffer.allocateDirect(modelBytes.size).order(ByteOrder.nativeOrder())
        buffer.put(modelBytes)
        buffer.rewind()

        var delegate: GpuDelegate? = null
        val replacement = try {
            val options = Interpreter.Options()
            // The GPU delegate is a large win per frame, but it is unavailable on
            // some hardware and on most emulators. Falling back to CPU keeps
            // detection working instead of losing it entirely.
            if (CompatibilityList().isDelegateSupportedOnThisDevice) {
                delegate = GpuDelegate()
                options.addDelegate(delegate)
            }
            Interpreter(buffer, options)
        } catch (e: Exception) {
            Log.w(TAG, "GPU-accelerated interpreter failed to load; retrying on CPU", e)
            delegate?.close()
            delegate = null
            Interpreter(buffer, Interpreter.Options())
        }

        // The model's actual geometry drives preprocessing, not an assumed
        // constant: a retrained model is not guaranteed to ship at the same
        // input size or channel order as the bundled default.
        val layout = YoloOutput.detectInputLayout(replacement.getInputTensor(0).shape())
        inputSize = layout.size
        channelsFirst = layout.channelsFirst
        outputShape = replacement.getOutputTensor(0).shape()
        if (!layout.recognized) {
            Log.w(
                TAG,
                "Model input shape ${replacement.getInputTensor(0).shape().toList()} is neither " +
                    "NHWC nor NCHW; guessing size=$inputSize, channel-last. Inference will throw " +
                    "if that mismatches what the interpreter expects.",
            )
        }
        warnOnUnexpectedGeometry()

        val previous = interpreter
        val previousDelegate = gpuDelegate
        interpreter = replacement
        gpuDelegate = delegate
        _isModelLoaded.value = true

        // A replacement model may have different shapes, so the cached buffers
        // are no longer valid.
        inputBuffer = null
        outputBuffer = null
        pixelBuffer = null
        floatScratch = null
        outputScratch = null

        previous?.close()
        previousDelegate?.close()

        Log.i(TAG, "Detector loaded (input ${inputSize}x$inputSize, ${layoutName()})")
    }

    /**
     * Logs the loaded model's geometry and warns — never throws — when it does
     * not look like the single-class YOLO11 detector the app expects.
     *
     * Warn-and-continue is deliberate. A model downloaded from the training
     * server is allowed to ship at a different geometry than the bundled asset,
     * and refusing to load it would break detection outright rather than
     * degrading. Everything downstream already adapts.
     */
    private fun warnOnUnexpectedGeometry() {
        Log.i(TAG, "Detector geometry: input ${inputSize}x$inputSize (${layoutName()}), " +
            "output ${outputShape.toList()}")

        if (inputSize % 32 != 0) {
            Log.w(TAG, "Input size $inputSize is not a multiple of 32, so the P5 stride grid " +
                "does not divide evenly.")
        }
        if (outputShape.size < 3) {
            Log.w(TAG, "Output shape ${outputShape.toList()} is not the expected " +
                "3-dimensional Detect head output.")
            return
        }

        // Ultralytics TFLite exports emit the transposed [1, 4+nc, N]; the
        // parser also accepts the standard [1, N, 4+nc].
        val transposed = outputShape[1] == 5 || outputShape[1] == 6
        val channels = if (transposed) outputShape[1] else outputShape[2]
        val anchors = if (transposed) outputShape[2] else outputShape[1]

        when {
            channels != 5 && channels != 6 ->
                Log.w(TAG, "Output has $channels channels; expected 5 (4 box coords + 1 class).")
            channels == 6 ->
                Log.i(TAG, "Model reports 2 classes; only class 0 (disc) is used.")
        }

        val expected = YoloOutput.expectedAnchors(inputSize)
        if (anchors != expected) {
            Log.w(TAG, "Output has $anchors anchors, but a ${inputSize}x$inputSize anchor-free " +
                "Detect head should produce $expected. The model may have been exported at a " +
                "different size than its input tensor declares.")
        }
    }

    private fun layoutName() = if (channelsFirst) "NCHW" else "NHWC"

    private fun downloadedModelFile(): File? =
        File(trainingDataDir, "models/disc_detector.tflite").takeIf { it.exists() }

    // ── Detection over a whole clip ──────────────────────────────────────

    /**
     * Ask an in-flight [processVideo] to stop at the next frame boundary.
     *
     * Granularity is one frame: inference is synchronous, so the frame already
     * in flight always finishes.
     */
    fun cancelProcessing() {
        if (_isProcessing.value) cancelRequested.set(true)
    }

    /**
     * Extract frames, detect the disc in each, then filter, smooth, and fill.
     *
     * [startMs] and [endMs] restrict extraction to the trimmed range, so every
     * returned frame index is relative to the trim start — the same space the
     * player and any user-placed keyframes use.
     */
    override suspend fun processVideo(
        videoPath: String,
        fps: Double,
        maxFrames: Int,
        startMs: Long,
        endMs: Long?,
    ): FlightTrackingResult {
        check(!processMutex.isLocked) {
            "DiscDetector.processVideo is already running; await the in-flight call " +
                "before starting another."
        }

        return processMutex.withLock {
            val framesDir = File(context.cacheDir, "disc_detect_${System.currentTimeMillis()}")
            try {
                // Reset progress before loading the model. On a fresh install the
                // load is the first thing the user waits on, and leaving the last
                // run's "Complete!" on screen makes the progress bar misleading.
                cancelRequested.set(false)
                _isProcessing.value = true
                _progressFlow.value = 0.0

                if (!_isModelLoaded.value) {
                    _statusFlow.value = "Loading detector..."
                    loadModel()
                }

                _statusFlow.value = "Extracting frames..."
                val frames = frameExtractor.extractFrames(
                    videoPath = videoPath,
                    outputDir = framesDir,
                    fps = fps,
                    maxFrames = maxFrames,
                    startMs = startMs,
                    endMs = endMs,
                )
                if (frames.isEmpty()) error("No frames could be extracted from the video")

                // Frame indices can be sparse if extraction skipped a frame, so
                // the span is the last index reached, not the count.
                val totalFrames = frames.last().index + 1
                _statusFlow.value = "Detecting disc in ${frames.size} frames..."

                val rawDetections = ArrayList<DiscDetection>()
                var firstImageW = 640.0
                var firstImageH = 1138.0
                var track: DiscTrack? = null

                withContext(Dispatchers.Default) {
                    for ((i, frame) in frames.withIndex()) {
                        _progressFlow.value = (i.toDouble() / frames.size) * 0.7
                        if (i % 10 == 0) {
                            _statusFlow.value = "Detecting disc: frame ${i + 1}/${frames.size}"
                        }

                        val bitmap = decodeFrame(frame.path) ?: continue
                        if (i == 0) {
                            firstImageW = bitmap.width.toDouble()
                            firstImageH = bitmap.height.toDouble()
                        }

                        var chosen: DiscDetection? = null
                        val currentTrack = track

                        if (currentTrack == null) {
                            // Discovery: a full-frame scan for the disc leaving the
                            // thrower's hand or in early flight.
                            chosen = detectInImage(bitmap, frame.index, fps)
                        } else {
                            // Tracking: search only where the track predicts the
                            // disc has moved to.
                            val gap = frame.index - currentTrack.lastFrameIndex
                            val (predictedX, predictedY) = currentTrack.predict(gap)
                            val candidates = detectInWindow(
                                bitmap = bitmap,
                                frameIndex = frame.index,
                                fps = fps,
                                centerX = predictedX,
                                centerY = predictedY,
                                regionSize = Trajectory.searchWindowSizeFor(gap),
                            )

                            if (candidates.isEmpty()) {
                                currentTrack.occlusionStreak++
                                if (currentTrack.occlusionStreak > Trajectory.MAX_OCCLUSION_FRAMES) {
                                    // Lost the lock — go back to full-frame discovery
                                    // rather than coast indefinitely.
                                    track = null
                                }
                            } else {
                                chosen = if (candidates.size == 1) {
                                    candidates.first()
                                } else {
                                    Trajectory.selectClosestCandidate(
                                        candidates,
                                        predictedX,
                                        predictedY,
                                    )
                                }
                            }
                        }

                        if (chosen != null) {
                            rawDetections += chosen
                            val existing = track
                            if (existing == null) {
                                track = DiscTrack(chosen.x, chosen.y, chosen.frameIndex)
                            } else {
                                existing.confirm(chosen)
                            }
                        }

                        bitmap.recycle()

                        if (cancelRequested.get()) throw DetectionCancelledException()
                    }
                }

                _progressFlow.value = 0.8
                _statusFlow.value = "Filtering trajectory..."
                val coherent = Trajectory.filterSpatialCoherence(rawDetections, totalFrames)

                _progressFlow.value = 0.9
                _statusFlow.value = "Smoothing..."
                val smoothed = Trajectory.smoothDetections(coherent, windowSize = 3)

                _progressFlow.value = 0.95
                _statusFlow.value = "Interpolating gaps..."
                val interpolated = Trajectory.interpolateDetections(smoothed, fps)

                _progressFlow.value = 1.0
                _statusFlow.value = "Complete!"

                FlightTrackingResult(
                    detections = interpolated,
                    videoWidth = firstImageW,
                    videoHeight = firstImageH,
                    fps = fps,
                    totalFrames = totalFrames,
                ).also { _lastResult.value = it }
            } finally {
                runCatching { framesDir.deleteRecursively() }
                cancelRequested.set(false)
                _isProcessing.value = false
            }
        }
    }

    // ── Single-frame detection ───────────────────────────────────────────

    /** The best detection in a whole frame, or null when nothing clears the bar. */
    fun detectInImage(bitmap: Bitmap, frameIndex: Int, fps: Double): DiscDetection? {
        val output = runInference(bitmap) ?: return null
        return YoloOutput.parseBestDetection(
            output = output,
            shape = outputShape,
            frameIndex = frameIndex,
            fps = fps,
            confidenceThreshold = confidenceThreshold,
            inputSize = inputSize,
        )
    }

    /**
     * Every candidate inside a square window of [bitmap], remapped back to
     * full-frame normalized coordinates.
     *
     * The crop is square in source pixels rather than squashed per axis, so a
     * window clamped against a frame edge does not hand the model a differently
     * distorted disc than one in the middle of the frame.
     */
    fun detectInWindow(
        bitmap: Bitmap,
        frameIndex: Int,
        fps: Double,
        centerX: Double,
        centerY: Double,
        regionSize: Double,
        maxCandidates: Int = 5,
    ): List<DiscDetection> {
        if (interpreter == null) return emptyList()

        val minDim = min(bitmap.width, bitmap.height)
        val side = (regionSize * minDim).roundToInt().coerceIn(20, minDim)
        val xMin = (centerX * bitmap.width - side / 2.0).roundToInt()
            .coerceIn(0, bitmap.width - side)
        val yMin = (centerY * bitmap.height - side / 2.0).roundToInt()
            .coerceIn(0, bitmap.height - side)

        val crop = Bitmap.createBitmap(bitmap, xMin, yMin, side, side)
        val output = try {
            runInference(crop) ?: return emptyList()
        } finally {
            if (crop !== bitmap) crop.recycle()
        }

        return YoloOutput.parseCandidateDetections(
            output = output,
            shape = outputShape,
            frameIndex = frameIndex,
            fps = fps,
            confidenceThreshold = confidenceThreshold,
            maxCandidates = maxCandidates,
            inputSize = inputSize,
        ).map { candidate ->
            candidate.copy(
                x = ((xMin + candidate.x * side) / bitmap.width).coerceIn(0.0, 1.0),
                y = ((yMin + candidate.y * side) / bitmap.height).coerceIn(0.0, 1.0),
                width = candidate.width * side / bitmap.width,
                height = candidate.height * side / bitmap.height,
            )
        }
    }

    /**
     * Run the model over [bitmap] and return its raw output.
     *
     * Buffers are allocated once per model and overwritten in place. A 640x640x3
     * input is over a million floats; rebuilding it per frame dominated the cost
     * of a multi-hundred-frame run.
     */
    private fun runInference(bitmap: Bitmap): FloatArray? {
        val interpreter = this.interpreter ?: return null

        val scaled = if (bitmap.width == inputSize && bitmap.height == inputSize) {
            bitmap
        } else {
            Bitmap.createScaledBitmap(bitmap, inputSize, inputSize, true)
        }

        val pixels = pixelBuffer
            ?.takeIf { it.size == inputSize * inputSize }
            ?: IntArray(inputSize * inputSize).also { pixelBuffer = it }
        scaled.getPixels(pixels, 0, inputSize, 0, 0, inputSize, inputSize)
        if (scaled !== bitmap) scaled.recycle()

        val floats = floatScratch
            ?.takeIf { it.size == YoloPreprocessor.bufferSize(inputSize) }
            ?: FloatArray(YoloPreprocessor.bufferSize(inputSize)).also { floatScratch = it }
        YoloPreprocessor.writeNormalizedInput(pixels, inputSize, channelsFirst, floats)

        val input = inputBuffer
            ?.takeIf { it.capacity() == floats.size * 4 }
            ?: ByteBuffer.allocateDirect(floats.size * 4)
                .order(ByteOrder.nativeOrder())
                .also { inputBuffer = it }
        input.rewind()
        input.asFloatBuffer().put(floats)

        val outputCount = outputShape.fold(1) { acc, dim -> acc * dim }
        val output = outputBuffer
            ?.takeIf { it.capacity() == outputCount * 4 }
            ?: ByteBuffer.allocateDirect(outputCount * 4)
                .order(ByteOrder.nativeOrder())
                .also { outputBuffer = it }
        output.rewind()

        return try {
            interpreter.run(input, output)
            output.rewind()
            val values = outputScratch
                ?.takeIf { it.size == outputCount }
                ?: FloatArray(outputCount).also { outputScratch = it }
            output.asFloatBuffer().get(values)
            values
        } catch (e: Exception) {
            Log.w(TAG, "Inference failed", e)
            null
        }
    }

    private fun decodeFrame(path: String): Bitmap? = runCatching {
        android.graphics.BitmapFactory.decodeFile(path)
    }.getOrNull()

    fun close() {
        interpreter?.close()
        interpreter = null
        gpuDelegate?.close()
        gpuDelegate = null
        _isModelLoaded.value = false
        inputBuffer = null
        outputBuffer = null
        pixelBuffer = null
        floatScratch = null
        outputScratch = null
    }

    private companion object {
        const val TAG = "DiscDetector"
    }
}
