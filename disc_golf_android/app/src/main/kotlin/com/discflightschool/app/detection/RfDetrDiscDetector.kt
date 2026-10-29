package com.discflightschool.app.detection

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import com.discflightschool.app.video.FrameExtractor
import com.discflightschool.core.data.DetectionSettings
import com.discflightschool.core.detection.DetectionCancelledException
import com.discflightschool.core.detection.DiscDetection
import com.discflightschool.core.detection.RfDetrConfig
import com.discflightschool.core.detection.RfDetrInput
import com.discflightschool.core.detection.RfDetrOutput
import com.discflightschool.core.tracking.FrameDetections
import com.discflightschool.core.tracking.TrackerDetection
import com.discflightschool.core.tracking.WorkflowDiscTracker
import com.discflightschool.core.tracking.WorkflowFrameDetector
import java.io.FileInputStream
import java.nio.FloatBuffer
import java.nio.channels.FileChannel
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

/**
 * The Roboflow Workflow's disc model, RF-DETR Small, run on the phone with
 * ONNX Runtime.
 *
 * The weights are Roboflow's own ONNX export of the model the Workflow runs,
 * bundled by scripts/fetch_disc_model.py, and the preprocessing and
 * post-processing are ported from Roboflow's `inference-models` package, so a
 * frame scores as it would in the Workflow. RF-DETR is Apache 2.0 licensed.
 *
 * App-scoped: the session holds the 114 MB model in native memory and takes
 * seconds to build.
 */
class RfDetrDiscDetector(
    private val context: Context,
    private val frameExtractor: FrameExtractor,
    /** The sensitivity for refining hand-marked paths; Auto-detect uses the Workflow's own. */
    private val settings: DetectionSettings,
) : WorkflowFrameDetector {

    private val environment by lazy { OrtEnvironment.getEnvironment() }
    private var session: OrtSession? = null
    private var config: RfDetrConfig? = null
    private var discClass = -1
    private var classCount = 0

    private val loadMutex = Mutex()
    private val runMutex = Mutex()
    /** Guards the session's shared input buffers between the auto and hybrid trackers. */
    private val inferenceMutex = Mutex()
    private val cancelRequested = AtomicBoolean(false)

    private val _progress = MutableStateFlow(0.0)
    val progressFlow: StateFlow<Double> = _progress.asStateFlow()
    private val _status = MutableStateFlow("")
    val statusFlow: StateFlow<String> = _status.asStateFlow()
    private val _isProcessing = MutableStateFlow(false)
    val isProcessing: StateFlow<Boolean> = _isProcessing.asStateFlow()

    private val _isModelLoaded = MutableStateFlow(false)
    val isModelLoaded: StateFlow<Boolean> = _isModelLoaded.asStateFlow()

    override val progress: Double get() = _progress.value
    override val statusMessage: String get() = _status.value

    override suspend fun loadModel() {
        if (session != null) return
        loadMutex.withLock {
            if (session != null) return
            withContext(Dispatchers.IO) {
                val loaded = RfDetrConfig.parse(
                    readAsset("$MODEL_DIR/inference_config.json"),
                    readAsset("$MODEL_DIR/class_names.txt"),
                )
                val disc = loaded.classIndex(DISC_CLASS)
                require(disc >= 0) { "The bundled model has no '$DISC_CLASS' class." }
                val options = OrtSession.SessionOptions().apply {
                    setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
                    setIntraOpNumThreads(Runtime.getRuntime().availableProcessors().coerceIn(1, 4))
                }
                // Mapped straight from the APK (the asset is stored uncompressed),
                // so the weights never pass through the Java heap.
                val created = context.assets.openFd("$MODEL_DIR/$WEIGHTS").use { fd ->
                    FileInputStream(fd.fileDescriptor).channel.use { channel ->
                        val weights = channel.map(FileChannel.MapMode.READ_ONLY, fd.startOffset, fd.declaredLength)
                        environment.createSession(weights, options)
                    }
                }
                classCount = loaded.classNames.size
                discClass = disc
                config = loaded
                session = created
                _isModelLoaded.value = true
                Log.i(TAG, "RF-DETR loaded: inputs ${created.inputNames}, outputs ${created.outputNames}")
            }
        }
    }

    /** Ask a running [detectFrames] to stop after the frame in progress. */
    fun cancelProcessing() {
        if (_isProcessing.value) cancelRequested.set(true)
    }

    override suspend fun detectFrames(
        videoPath: String,
        fps: Double,
        maxFrames: Int,
        startMs: Long,
        endMs: Long?,
        onFrame: (FrameDetections) -> Unit,
    ) {
        check(!runMutex.isLocked) { "RfDetrDiscDetector is already running." }
        runMutex.withLock {
            cancelRequested.set(false)
            _isProcessing.value = true
            _progress.value = 0.0
            try {
                if (session == null) {
                    _status.value = "Loading detector..."
                    loadModel()
                }
                val total = maxFrames.coerceAtLeast(1)
                _status.value = "Finding the disc..."
                frameExtractor.forEachFullFrame(videoPath, fps, maxFrames, startMs, endMs) { index, timeMs, bitmap ->
                    if (cancelRequested.get()) throw DetectionCancelledException()
                    val detections = withContext(Dispatchers.Default) { detect(bitmap, WorkflowDiscTracker.CONFIDENCE_THRESHOLD) }
                    onFrame(FrameDetections(index, timeMs, bitmap.width, bitmap.height, detections))
                    _progress.value = ((index + 1).toDouble() / total).coerceAtMost(1.0)
                    _status.value = "Finding the disc: frame ${index + 1} of about $total"
                }
                if (cancelRequested.get()) throw DetectionCancelledException()
                _progress.value = 1.0
                _status.value = "Complete!"
            } finally {
                cancelRequested.set(false)
                _isProcessing.value = false
            }
        }
    }

    /**
     * Every disc inside a square window of [bitmap], most confident first, at
     * most [maxCandidates], in full-frame normalized coordinates. Empty when
     * the model is not loaded.
     *
     * The crop is square in source pixels, so a window clamped against a frame
     * edge hands the model the same proportions as one mid-frame. Candidates
     * must clear the user's sensitivity setting.
     */
    suspend fun detectInWindow(
        bitmap: Bitmap,
        frameIndex: Int,
        fps: Double,
        centerX: Double,
        centerY: Double,
        regionSize: Double,
        maxCandidates: Int = 5,
    ): List<DiscDetection> = withContext(Dispatchers.Default) {
        if (session == null) return@withContext emptyList()
        val minDim = min(bitmap.width, bitmap.height)
        val side = (regionSize * minDim).roundToInt().coerceIn(20, minDim)
        val xMin = (centerX * bitmap.width - side / 2.0).roundToInt().coerceIn(0, bitmap.width - side)
        val yMin = (centerY * bitmap.height - side / 2.0).roundToInt().coerceIn(0, bitmap.height - side)
        val crop = Bitmap.createBitmap(bitmap, xMin, yMin, side, side)
        val found = try {
            detect(crop, settings.confidenceThreshold.value)
        } finally {
            if (crop !== bitmap) crop.recycle()
        }
        found.take(maxCandidates).map { detection ->
            val box = detection.box
            DiscDetection(
                frameIndex = frameIndex,
                x = ((xMin + box.centerX) / bitmap.width).coerceIn(0.0, 1.0),
                y = ((yMin + box.centerY) / bitmap.height).coerceIn(0.0, 1.0),
                width = (box.x2 - box.x1) / bitmap.width,
                height = (box.y2 - box.y1) / bitmap.height,
                confidence = detection.confidence,
                timestampMs = DiscDetection.timestampFor(frameIndex, fps),
            )
        }
    }

    private var pixels = IntArray(0)
    private var input = FloatArray(0)

    /** Every disc in one frame scoring above [threshold], in frame pixels, most confident first. */
    private suspend fun detect(bitmap: Bitmap, threshold: Double): List<TrackerDetection> =
        inferenceMutex.withLock { detectLocked(bitmap, threshold) }

    private fun detectLocked(bitmap: Bitmap, threshold: Double): List<TrackerDetection> {
        val session = checkNotNull(session)
        val config = checkNotNull(config)
        val width = bitmap.width
        val height = bitmap.height
        if (pixels.size != width * height) pixels = IntArray(width * height)
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
        val size = 3 * config.inputWidth * config.inputHeight
        if (input.size != size) input = FloatArray(size)
        RfDetrInput.write(pixels, width, height, config, input)

        val shape = longArrayOf(1, 3, config.inputHeight.toLong(), config.inputWidth.toLong())
        return OnnxTensor.createTensor(environment, FloatBuffer.wrap(input), shape).use { tensor ->
            session.run(mapOf(session.inputNames.first() to tensor)).use { result ->
                val boxes = result.floats(BOXES_OUTPUT)
                val logits = result.floats(LOGITS_OUTPUT)
                RfDetrOutput.decode(boxes, logits, classCount, discClass, threshold, config, width, height)
            }
        }
    }

    private fun OrtSession.Result.floats(name: String): FloatArray {
        val buffer = (get(name).orElseThrow { IllegalStateException("The model has no '$name' output.") } as OnnxTensor)
            .floatBuffer
        return FloatArray(buffer.remaining()).also { buffer.get(it) }
    }

    private fun readAsset(path: String) = context.assets.open(path).bufferedReader().use { it.readText() }

    fun close() {
        _isModelLoaded.value = false
        session?.close()
        session = null
    }

    private companion object {
        const val TAG = "RfDetrDiscDetector"
        const val MODEL_DIR = "models/rfdetr"
        const val WEIGHTS = "weights.onnx"
        const val DISC_CLASS = "disc"
        const val BOXES_OUTPUT = "dets"
        const val LOGITS_OUTPUT = "labels"
    }
}
