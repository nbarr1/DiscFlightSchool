package com.discflightschool.app.ui.screens.flighttracker

import android.graphics.Bitmap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.AutoFixHigh
import androidx.compose.material.icons.filled.CenterFocusStrong
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.CropFree
import androidx.compose.material.icons.filled.EditLocationAlt
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Save
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Straighten
import androidx.compose.material.icons.filled.Undo
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.detection.HybridDiscTracker
import com.discflightschool.app.ui.Formatting
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.components.FlightPathOverlay
import com.discflightschool.app.ui.components.LoadingState
import com.discflightschool.app.ui.theme.AppColors
import com.discflightschool.app.video.FlightVideoExporter
import com.discflightschool.app.video.VideoSurface
import com.discflightschool.app.video.rememberPlaybackState
import com.discflightschool.app.video.rememberVideoPlayer
import com.discflightschool.core.data.KeyframeData
import com.discflightschool.core.detection.DetectionCancelledException
import com.discflightschool.core.detection.DetectionQualityFlag
import com.discflightschool.core.detection.DetectionQualityReport
import com.discflightschool.core.detection.DetectorModelUnavailableException
import com.discflightschool.core.detection.assessDetectionQuality
import com.discflightschool.core.detection.sampleSeedPoints
import com.discflightschool.core.geometry.Vec2
import com.discflightschool.core.tracking.AutoDiscTracker
import com.discflightschool.core.tracking.FrameIndexing
import com.discflightschool.core.tracking.GeometricSplineTracker
import com.discflightschool.core.tracking.TrackerSeedPoint
import com.discflightschool.core.tracking.TrackerSession
import com.discflightschool.core.tracking.WorldAnchorFrame
import java.io.File
import kotlin.math.max
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

/** The guided setup steps for tracking a throw. */
private enum class SetupPhase { CAMERA, ANCHORING, MARKING, RESULT }

/** Which tracker produced the path currently on screen. */
private enum class TrackSource { MANUAL, HYBRID, AUTO }

/** A disc position the user marked at one frame. */
private data class FlightKeyframe(
    val frameIndex: Int,
    val x: Double,
    val y: Double,
    val boxWidth: Double? = null,
    val boxHeight: Double? = null,
    /**
     * True when this point came from the detector rather than the user's
     * finger. Derived points are excluded from training data: uploading the
     * detector's own output as ground truth would train the next model on this
     * one's mistakes.
     */
    val derived: Boolean = false,
)

/**
 * Tracks the disc through a clip and draws its flight path.
 *
 * Three routes to a path: the detector finds it alone, the user marks it by
 * hand, or the user marks a few points and the detector refines between them.
 * A moving camera is handled first, by anchoring two fixed background points so
 * the trail stays pinned to the ground instead of sliding with the pan.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun FlightPlayerScreen(onBack: () -> Unit) {
    val container = LocalAppContainer.current
    val context = LocalContext.current
    val density = LocalDensity.current
    val workbench = container.workbench
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }

    val videoPath = workbench.flightVideoPath
    if (videoPath == null) {
        Scaffold(topBar = { AppTopBar(title = "Flight tracker", onBack = onBack) }) { padding ->
            LoadingState("No video selected", Modifier.padding(padding))
        }
        return
    }

    val trimStartMs = workbench.flightTrimStartMs
    val trimEndMs = workbench.flightTrimEndMs

    val player = rememberVideoPlayer(videoPath)
    val playback = rememberPlaybackState(player)
    val detectorProgress by container.discDetector.progressFlow.collectAsStateWithLifecycle()
    val detectorStatus by container.discDetector.statusFlow.collectAsStateWithLifecycle()
    val isDetecting by container.discDetector.isProcessing.collectAsStateWithLifecycle()
    val isOptedIn by container.trainingDataRepository.isOptedIn.collectAsStateWithLifecycle()

    var phase by remember { mutableStateOf(SetupPhase.CAMERA) }
    var showOverlay by remember { mutableStateOf(true) }
    var currentFrame by remember { mutableIntStateOf(0) }
    var videoSize by remember { mutableStateOf(Size.Zero) }
    var resultSource by remember { mutableStateOf<TrackSource?>(null) }
    var qualityReport by remember { mutableStateOf<DetectionQualityReport?>(null) }

    val keyframes = remember { mutableStateListOf<FlightKeyframe>() }
    val anchors = remember { mutableStateListOf<WorldAnchorFrame>() }
    var pendingAnchor by remember { mutableStateOf<Vec2?>(null) }

    var boxMode by remember { mutableStateOf(false) }
    var pendingBoxCorner by remember { mutableStateOf<Vec2?>(null) }
    var targetLineMode by remember { mutableStateOf(false) }
    var targetStart by remember { mutableStateOf<Vec2?>(null) }
    var targetEnd by remember { mutableStateOf<Vec2?>(null) }

    var magnifierAt by remember { mutableStateOf<androidx.compose.ui.geometry.Offset?>(null) }
    var magnifierBitmap by remember { mutableStateOf<Bitmap?>(null) }

    var showModeSheet by remember { mutableStateOf(true) }
    var showCameraSheet by remember { mutableStateOf(false) }
    var busyMessage by remember { mutableStateOf<String?>(null) }
    var showDetectionDialog by remember { mutableStateOf(false) }
    var exportProgress by remember { mutableStateOf<Float?>(null) }

    val result = workbench.flightResult

    LaunchedEffect(videoPath) { player.seekTo(trimStartMs) }

    // Keep the frame counter in the trimmed space every tracker uses, and stop
    // playback at the end of the trim.
    LaunchedEffect(playback.positionMs) {
        if (trimEndMs != null && playback.positionMs >= trimEndMs && playback.isPlaying) {
            player.pause()
            player.seekTo(trimEndMs)
        }
        val frame = FrameIndexing.frameIndexAt(playback.positionMs, trimStartMs, TRACK_FPS)
        if (frame != currentFrame) currentFrame = frame
    }

    LaunchedEffect(magnifierAt != null, currentFrame) {
        if (magnifierAt == null) {
            magnifierBitmap?.recycle()
            magnifierBitmap = null
            return@LaunchedEffect
        }
        if (magnifierBitmap == null) {
            magnifierBitmap = container.frameExtractor.frameBitmapAt(
                videoPath,
                trimStartMs + FrameIndexing.timestampOf(currentFrame, TRACK_FPS),
            )
        }
    }

    fun buildSession(): TrackerSession {
        val spanMs = (trimEndMs ?: playback.durationMs) - trimStartMs
        val frames = (spanMs * TRACK_FPS / 1000).roundToInt() + 1
        return TrackerSession(
            videoPath = videoPath,
            fps = TRACK_FPS,
            totalFrames = max(1, frames),
            videoWidth = videoSize.width.toDouble().takeIf { it > 0 } ?: 1080.0,
            videoHeight = videoSize.height.toDouble().takeIf { it > 0 } ?: 1920.0,
            trimStartMs = trimStartMs,
            trimEndMs = trimEndMs,
        )
    }

    fun seedPoints(): List<TrackerSeedPoint> = keyframes
        .map { TrackerSeedPoint(frameIndex = it.frameIndex, x = it.x, y = it.y) }

    suspend fun collectTrainingData() {
        if (!isOptedIn) return
        val data = keyframes
            .filterNot { it.derived }
            .map {
                KeyframeData(
                    frameIndex = it.frameIndex,
                    x = it.x,
                    y = it.y,
                    boxWidth = it.boxWidth,
                    boxHeight = it.boxHeight,
                )
            }
        if (data.isEmpty()) return

        val saved = container.trainingDataCollector.collectFromKeyframes(
            keyframes = data,
            videoPath = videoPath,
            fps = TRACK_FPS,
            trimStartMs = trimStartMs,
        )
        if (saved > 0) {
            snackbarHostState.showSnackbar("Saved $saved training samples")
            if (container.trainingDataRepository.serverUrl.value.isNotBlank()) {
                container.trainingDataCollector.uploadPending()
            }
        }
    }

    fun placeKeyframe(normalized: Vec2) {
        if (boxMode && pendingBoxCorner == null) {
            pendingBoxCorner = normalized
            return
        }

        val corner = pendingBoxCorner
        val keyframe = if (boxMode && corner != null) {
            FlightKeyframe(
                frameIndex = currentFrame,
                x = (corner.x + normalized.x) / 2,
                y = (corner.y + normalized.y) / 2,
                boxWidth = kotlin.math.abs(normalized.x - corner.x),
                boxHeight = kotlin.math.abs(normalized.y - corner.y),
            )
        } else {
            FlightKeyframe(frameIndex = currentFrame, x = normalized.x, y = normalized.y)
        }

        keyframes.removeAll { it.frameIndex == currentFrame }
        keyframes.add(keyframe)
        keyframes.sortBy { it.frameIndex }
        pendingBoxCorner = null
        workbench.flightResult = null
        resultSource = null
        qualityReport = null
    }

    fun placeAnchorPoint(normalized: Vec2) {
        val first = pendingAnchor
        if (first == null) {
            pendingAnchor = normalized
            return
        }
        anchors.removeAll { it.frameIndex == currentFrame }
        anchors.add(
            WorldAnchorFrame(frameIndex = currentFrame, pointA = first, pointB = normalized),
        )
        anchors.sortBy { it.frameIndex }
        pendingAnchor = null
    }

    fun onCanvasTap(offset: androidx.compose.ui.geometry.Offset) {
        if (videoSize == Size.Zero) return
        val normalized = Vec2(
            (offset.x / videoSize.width).toDouble().coerceIn(0.0, 1.0),
            (offset.y / videoSize.height).toDouble().coerceIn(0.0, 1.0),
        )

        when {
            phase == SetupPhase.ANCHORING -> placeAnchorPoint(normalized)
            targetLineMode -> {
                if (targetStart == null) {
                    targetStart = normalized
                } else {
                    targetEnd = normalized
                    targetLineMode = false
                }
            }
            phase == SetupPhase.MARKING -> placeKeyframe(normalized)
        }
    }

    suspend fun runAutoDetection() {
        if (isDetecting) return
        player.pause()
        showDetectionDialog = true
        val tracker = AutoDiscTracker(container.discDetector)

        try {
            val tracked = tracker.track(buildSession(), emptyList())
            showDetectionDialog = false

            if (tracked.detections.size < 2) {
                snackbarHostState.showSnackbar(
                    "We couldn't find the disc in this clip — try marking it by hand.",
                )
                phase = SetupPhase.MARKING
                return
            }

            workbench.flightResult = tracked
            workbench.flightWasAutoDetected = true
            resultSource = TrackSource.AUTO
            qualityReport = assessDetectionQuality(
                result = tracked,
                confidenceFloor = container.discDetector.confidenceThreshold,
            )
            phase = SetupPhase.RESULT
            // Rewind so the trail plays from the top rather than from wherever
            // the scrub position happened to be when detection started.
            player.seekTo(trimStartMs)
        } catch (e: DetectionCancelledException) {
            showDetectionDialog = false
            snackbarHostState.showSnackbar("Auto-detect cancelled — nothing was changed.")
            showModeSheet = true
        } catch (e: DetectorModelUnavailableException) {
            showDetectionDialog = false
            snackbarHostState.showSnackbar(
                "The detector model couldn't load — mark the disc by hand for now.",
            )
            showCameraSheet = true
        } catch (e: Exception) {
            showDetectionDialog = false
            snackbarHostState.showSnackbar("Detection failed: ${e.message ?: "unknown error"}")
            phase = SetupPhase.MARKING
        } finally {
            showDetectionDialog = false
            tracker.dispose()
        }
    }

    suspend fun processKeyframes() {
        if (keyframes.size < 2) return
        val tracked = GeometricSplineTracker().track(buildSession(), seedPoints())
        workbench.flightResult = tracked
        workbench.flightWasAutoDetected = false
        resultSource = TrackSource.MANUAL
        qualityReport = null
        phase = SetupPhase.RESULT
        collectTrainingData()
    }

    suspend fun refineWithDetection() {
        if (keyframes.size < 3) return
        busyMessage = "Detecting disc in frames..."
        val tracker = HybridDiscTracker(
            detector = container.discDetector,
            frameExtractor = container.frameExtractor,
            cacheDir = context.cacheDir,
        )
        try {
            val tracked = tracker.track(buildSession(), seedPoints())
            workbench.flightResult = tracked
            workbench.flightWasAutoDetected = false
            resultSource = TrackSource.HYBRID
            qualityReport = null
            phase = SetupPhase.RESULT
            if (!tracker.usedDetectorModel) {
                snackbarHostState.showSnackbar(
                    "Refined without the detector model — accuracy is reduced.",
                )
            }
            collectTrainingData()
        } catch (e: Exception) {
            snackbarHostState.showSnackbar("Detection failed: ${e.message ?: "unknown error"}")
        } finally {
            busyMessage = null
            tracker.dispose()
        }
    }

    fun convertResultToKeyframes() {
        val tracked = workbench.flightResult ?: return
        val sampled = sampleSeedPoints(tracked.detections)
        if (sampled.size < 2) return

        // Deliberately not a full reset: the anchors belong to this clip and
        // the whole point of coming back here is to keep working on it.
        keyframes.clear()
        keyframes.addAll(
            sampled.map {
                FlightKeyframe(frameIndex = it.frameIndex, x = it.x, y = it.y, derived = true)
            },
        )
        workbench.flightResult = null
        resultSource = null
        qualityReport = null
        pendingBoxCorner = null
        phase = SetupPhase.MARKING
        scope.launch {
            snackbarHostState.showSnackbar(
                "Added ${sampled.size} points — step to any that look wrong, tap the disc " +
                    "again, then tap Process.",
            )
        }
    }

    suspend fun saveVideoWithOverlay() {
        val tracked = workbench.flightResult ?: return
        if (tracked.detections.isEmpty()) return

        exportProgress = 0f
        try {
            val exported = FlightVideoExporter(context).export(
                videoPath = videoPath,
                result = tracked,
                trimStartMs = trimStartMs,
                trimEndMs = trimEndMs,
                anchors = anchors.toList(),
                outputDir = File(context.cacheDir, "exports"),
                onProgress = { exportProgress = it },
            )

            container.flightGalleryRepository.save(exported.absolutePath)
            val savedToGallery = container.videoLibrary.saveToGallery(exported)

            snackbarHostState.showSnackbar(
                if (savedToGallery) {
                    "Saved to the Disc Flight School album and the app gallery."
                } else {
                    "Saved to the app gallery."
                },
            )
        } catch (e: Exception) {
            snackbarHostState.showSnackbar("Failed to save: ${e.message ?: "unknown error"}")
        } finally {
            exportProgress = null
        }
    }

    Scaffold(
        topBar = {
            AppTopBar(title = "Flight tracker", onBack = onBack) {
                IconButton(onClick = { showOverlay = !showOverlay }) {
                    Icon(
                        if (showOverlay) Icons.Default.Visibility else Icons.Default.VisibilityOff,
                        contentDescription = if (showOverlay) "Hide overlay" else "Show overlay",
                    )
                }
                if (result != null) {
                    IconButton(onClick = { scope.launch { saveVideoWithOverlay() } }) {
                        Icon(Icons.Default.Save, contentDescription = "Save video with overlay")
                    }
                }
            }
        },
        snackbarHost = { SnackbarHost(snackbarHostState) },
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize(),
        ) {
            PhaseBanner(phase = phase, pendingAnchor = pendingAnchor, report = qualityReport)

            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .background(Color.Black)
                    .onSizeChanged { videoSize = Size(it.width.toFloat(), it.height.toFloat()) }
                    .pointerInput(phase, boxMode, targetLineMode, currentFrame) {
                        detectTapGestures(
                            onTap = { onCanvasTap(it) },
                            onLongPress = { offset ->
                                player.pause()
                                magnifierAt = offset
                            },
                            onPress = { offset ->
                                // A long press ends here, and that release is
                                // what places the point under the magnifier.
                                tryAwaitRelease()
                                if (magnifierAt != null) {
                                    onCanvasTap(magnifierAt ?: offset)
                                    magnifierAt = null
                                }
                            },
                        )
                    },
            ) {
                VideoSurface(player, Modifier.fillMaxSize())

                if (showOverlay) {
                    val tracked = result
                    if (tracked != null && tracked.detections.isNotEmpty()) {
                        FlightPathOverlay(
                            result = tracked,
                            currentFrame = currentFrame,
                            showFullTrail = true,
                            showCurrentDisc = phase != SetupPhase.RESULT,
                            anchors = anchors.toList(),
                            targetLine = targetStart?.let { start ->
                                targetEnd?.let { end -> start to end }
                            },
                            modifier = Modifier.fillMaxSize(),
                        )
                    }

                    if (phase == SetupPhase.MARKING) {
                        KeyframeMarkers(
                            keyframes = keyframes,
                            currentFrame = currentFrame,
                            pendingCorner = pendingBoxCorner,
                            modifier = Modifier.fillMaxSize(),
                        )
                    }

                    if (phase == SetupPhase.ANCHORING) {
                        AnchorMarkers(
                            anchors = anchors,
                            pending = pendingAnchor,
                            currentFrame = currentFrame,
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                }

                val magnifier = magnifierAt
                val bitmap = magnifierBitmap
                if (magnifier != null && bitmap != null) {
                    Magnifier(
                        bitmap = bitmap,
                        focus = magnifier,
                        canvasSize = videoSize,
                        offsetPx = with(density) {
                            IntOffset(
                                (magnifier.x - 70.dp.toPx()).roundToInt(),
                                (magnifier.y - 180.dp.toPx()).roundToInt(),
                            )
                        },
                    )
                }

                if (targetLineMode) {
                    Text(
                        text = if (targetStart == null) {
                            "Tap the start of your target line"
                        } else {
                            "Tap the target"
                        },
                        modifier = Modifier
                            .align(Alignment.TopCenter)
                            .padding(8.dp)
                            .background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(12.dp))
                            .padding(horizontal = 14.dp, vertical = 6.dp),
                        style = MaterialTheme.typography.labelMedium,
                        color = Color.White,
                    )
                }
            }

            StatsBar(
                keyframeCount = keyframes.size,
                pointCount = result?.detections?.size,
                currentFrame = currentFrame,
            )

            PlaybackBar(
                positionMs = playback.positionMs,
                startMs = trimStartMs,
                endMs = trimEndMs ?: playback.durationMs,
                isPlaying = playback.isPlaying,
                onPlayPause = { if (playback.isPlaying) player.pause() else player.play() },
                onStep = { forward ->
                    player.pause()
                    val step = (1000 / TRACK_FPS).roundToInt()
                    val target = playback.positionMs + if (forward) step else -step
                    player.seekTo(
                        target.coerceIn(trimStartMs, trimEndMs ?: playback.durationMs),
                    )
                },
                onSeek = { player.seekTo(it) },
            )

            ActionBar(
                phase = phase,
                keyframeCount = keyframes.size,
                anchorCount = anchors.size,
                resultSource = resultSource,
                isDetecting = isDetecting,
                showBoxToggle = isOptedIn,
                boxMode = boxMode,
                onToggleBoxMode = {
                    boxMode = !boxMode
                    pendingBoxCorner = null
                },
                onContinueFromAnchoring = { phase = SetupPhase.MARKING },
                onRedoAnchors = {
                    anchors.clear()
                    pendingAnchor = null
                },
                onOpenAnchoring = { phase = SetupPhase.ANCHORING },
                onUndo = {
                    if (keyframes.isNotEmpty()) {
                        keyframes.removeAt(keyframes.lastIndex)
                        workbench.flightResult = null
                        resultSource = null
                        qualityReport = null
                    }
                },
                onProcess = { scope.launch { processKeyframes() } },
                onRefine = { scope.launch { refineWithDetection() } },
                onAutoDetect = { scope.launch { runAutoDetection() } },
                onClear = {
                    keyframes.clear()
                    anchors.clear()
                    pendingAnchor = null
                    pendingBoxCorner = null
                    workbench.flightResult = null
                    resultSource = null
                    qualityReport = null
                    phase = SetupPhase.MARKING
                },
                onEditPoints = { convertResultToKeyframes() },
                onBackToMarking = { phase = SetupPhase.MARKING },
                onTargetLine = {
                    targetLineMode = true
                    targetStart = null
                    targetEnd = null
                },
            )
        }
    }

    if (showModeSheet) {
        ChoiceSheet(
            title = "How should we find the disc?",
            body = "Auto-detect scans the clip for you. Marking by hand is slower, but more " +
                "reliable on busy backgrounds.",
            secondaryLabel = "Mark manually",
            primaryLabel = "Auto-detect",
            onSecondary = {
                showModeSheet = false
                showCameraSheet = true
            },
            onPrimary = {
                showModeSheet = false
                scope.launch { runAutoDetection() }
            },
        )
    }

    if (showCameraSheet) {
        ChoiceSheet(
            title = "Was the camera stationary?",
            body = "If the camera panned or zoomed during the throw, we'll correct for it first.",
            secondaryLabel = "Yes, camera was fixed",
            primaryLabel = "It moved",
            onSecondary = {
                showCameraSheet = false
                phase = SetupPhase.MARKING
            },
            onPrimary = {
                showCameraSheet = false
                phase = SetupPhase.ANCHORING
            },
        )
    }

    if (showDetectionDialog) {
        AlertDialog(
            onDismissRequest = {},
            title = { Text("Finding the disc") },
            text = {
                Column {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        LinearProgressIndicator(
                            progress = { detectorProgress.toFloat().coerceIn(0f, 1f) },
                            modifier = Modifier.weight(1f),
                        )
                        Spacer(Modifier.width(12.dp))
                        Text("${(detectorProgress * 100).roundToInt()}%")
                    }
                    Spacer(Modifier.height(16.dp))
                    Text(
                        detectorStatus.ifEmpty { "Starting..." },
                        style = MaterialTheme.typography.bodySmall,
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Keep the app open — this can take a minute.",
                        style = MaterialTheme.typography.labelSmall,
                        color = AppColors.Muted,
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = { container.discDetector.cancelProcessing() }) {
                    Text("Cancel")
                }
            },
        )
    }

    busyMessage?.let { message ->
        AlertDialog(
            onDismissRequest = {},
            confirmButton = {},
            text = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator()
                    Spacer(Modifier.width(16.dp))
                    Text(message)
                }
            },
        )
    }

    exportProgress?.let { progress ->
        AlertDialog(
            onDismissRequest = {},
            confirmButton = {},
            title = { Text("Rendering flight path") },
            text = {
                Column {
                    LinearProgressIndicator(
                        progress = { progress },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(12.dp))
                    Text(
                        "Drawing the trail into a copy of your video.",
                        style = MaterialTheme.typography.bodySmall,
                        color = AppColors.Muted,
                    )
                }
            },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChoiceSheet(
    title: String,
    body: String,
    secondaryLabel: String,
    primaryLabel: String,
    onSecondary: () -> Unit,
    onPrimary: () -> Unit,
) {
    ModalBottomSheet(
        // The sheet is the question; dismissing it would leave the screen with
        // no path chosen and nothing to do.
        onDismissRequest = {},
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = AppColors.Background,
    ) {
        Column(Modifier.padding(start = 24.dp, top = 8.dp, end = 24.dp, bottom = 32.dp)) {
            Text(
                title,
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(8.dp))
            Text(body, style = MaterialTheme.typography.bodyMedium, color = AppColors.Muted)
            Spacer(Modifier.height(28.dp))
            Row {
                OutlinedButton(onClick = onSecondary, modifier = Modifier.weight(1f)) {
                    Text(secondaryLabel)
                }
                Spacer(Modifier.width(12.dp))
                Button(
                    onClick = onPrimary,
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(containerColor = AppColors.Roulette),
                ) {
                    Text(primaryLabel)
                }
            }
        }
    }
}

@Composable
private fun PhaseBanner(
    phase: SetupPhase,
    pendingAnchor: Vec2?,
    report: DetectionQualityReport?,
) {
    val content: Triple<String, String, Color>? = when (phase) {
        SetupPhase.ANCHORING -> Triple(
            "Step 1 of 2 — anchor the environment",
            if (pendingAnchor == null) {
                "Tap point A — a fixed background landmark (a tree, a basket, a sign)."
            } else {
                "Now tap point B — a second distinct landmark in the same frame."
            },
            AppColors.KnowledgeBase,
        )
        SetupPhase.MARKING -> Triple(
            "Step 2 of 2 — mark the disc",
            "Tap the disc in two or more frames (hold for a zoomed view), then tap Process.",
            AppColors.TopBar,
        )
        SetupPhase.RESULT -> report?.takeIf { it.isLow }?.let {
            Triple(
                "Low confidence — check this path",
                lowConfidenceDetail(it.primaryFlag),
                AppColors.Warning,
            )
        }
        SetupPhase.CAMERA -> null
    } ?: return

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(content.third.copy(alpha = 0.22f))
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Text(
            content.first,
            fontWeight = FontWeight.Bold,
            style = MaterialTheme.typography.labelLarge,
        )
        Spacer(Modifier.height(2.dp))
        Text(
            content.second,
            style = MaterialTheme.typography.labelMedium,
            color = AppColors.Muted,
        )
    }
}

/** Explains, in the user's terms, what was wrong with an automatic track. */
private fun lowConfidenceDetail(flag: DetectionQualityFlag?): String = when (flag) {
    DetectionQualityFlag.TOO_FEW_DETECTIONS ->
        "We only locked onto the disc for a few frames. Keep it, or tap Edit points to fix " +
            "it by hand."
    DetectionQualityFlag.LOW_COVERAGE ->
        "The path covers less than half the clip — the disc may leave frame early."
    DetectionQualityFlag.MOSTLY_INTERPOLATED ->
        "Most of this path is filled in between sightings, not detected."
    DetectionQualityFlag.WEAK_MATCHES ->
        "The matches were weak — this may be tracking something other than the disc."
    null -> ""
}

@Composable
private fun KeyframeMarkers(
    keyframes: List<FlightKeyframe>,
    currentFrame: Int,
    pendingCorner: Vec2?,
    modifier: Modifier = Modifier,
) {
    Canvas(modifier) {
        for (keyframe in keyframes) {
            val center = androidx.compose.ui.geometry.Offset(
                keyframe.x.toFloat() * size.width,
                keyframe.y.toFloat() * size.height,
            )
            val alpha = if (keyframe.frameIndex == currentFrame) 1f else 0.4f
            drawCircle(
                Color.Yellow.copy(alpha = alpha * 0.3f),
                radius = 10.dp.toPx(),
                center = center,
            )
            drawCircle(
                Color.Yellow.copy(alpha = alpha),
                radius = 6.dp.toPx(),
                center = center,
                style = Stroke(width = 2.dp.toPx()),
            )

            val boxWidth = keyframe.boxWidth
            val boxHeight = keyframe.boxHeight
            if (boxWidth != null && boxHeight != null) {
                val width = boxWidth.toFloat() * size.width
                val height = boxHeight.toFloat() * size.height
                drawRect(
                    color = Color(0xFFFFA726).copy(alpha = alpha),
                    topLeft = androidx.compose.ui.geometry.Offset(
                        center.x - width / 2,
                        center.y - height / 2,
                    ),
                    size = Size(width, height),
                    style = Stroke(width = 1.5.dp.toPx()),
                )
            }
        }

        pendingCorner?.let { corner ->
            val center = androidx.compose.ui.geometry.Offset(
                corner.x.toFloat() * size.width,
                corner.y.toFloat() * size.height,
            )
            drawCircle(
                Color.Magenta,
                radius = 8.dp.toPx(),
                center = center,
                style = Stroke(width = 2.dp.toPx()),
            )
        }
    }
}

@Composable
private fun AnchorMarkers(
    anchors: List<WorldAnchorFrame>,
    pending: Vec2?,
    currentFrame: Int,
    modifier: Modifier = Modifier,
) {
    Canvas(modifier) {
        fun draw(point: Vec2, color: Color, label: Boolean) {
            val center = androidx.compose.ui.geometry.Offset(
                point.x.toFloat() * size.width,
                point.y.toFloat() * size.height,
            )
            drawCircle(color.copy(alpha = 0.25f), radius = 12.dp.toPx(), center = center)
            drawCircle(
                color,
                radius = 7.dp.toPx(),
                center = center,
                style = Stroke(width = if (label) 2.5.dp.toPx() else 1.5.dp.toPx()),
            )
        }

        for (anchor in anchors) {
            val isCurrent = anchor.frameIndex == currentFrame
            val color = if (isCurrent) AppColors.KnowledgeBase else AppColors.Muted
            draw(anchor.pointA, color, isCurrent)
            draw(anchor.pointB, color, isCurrent)
            if (isCurrent) {
                drawLine(
                    color = color,
                    start = androidx.compose.ui.geometry.Offset(
                        anchor.pointA.x.toFloat() * size.width,
                        anchor.pointA.y.toFloat() * size.height,
                    ),
                    end = androidx.compose.ui.geometry.Offset(
                        anchor.pointB.x.toFloat() * size.width,
                        anchor.pointB.y.toFloat() * size.height,
                    ),
                    strokeWidth = 1.5.dp.toPx(),
                )
            }
        }

        pending?.let { draw(it, Color.Cyan, true) }
    }
}

@Composable
private fun Magnifier(
    bitmap: Bitmap,
    focus: androidx.compose.ui.geometry.Offset,
    canvasSize: Size,
    offsetPx: IntOffset,
) {
    Box(
        modifier = Modifier
            .offset { offsetPx }
            .size(140.dp)
            .background(Color.Black, CircleShape)
            .border(2.dp, AppColors.Accent, CircleShape),
    ) {
        Canvas(Modifier.fillMaxSize()) {
            if (canvasSize == Size.Zero) return@Canvas
            val zoom = 2.5f
            val sourceX = (focus.x / canvasSize.width) * bitmap.width
            val sourceY = (focus.y / canvasSize.height) * bitmap.height
            val windowWidth = size.width / zoom
            val windowHeight = size.height / zoom

            drawImage(
                image = bitmap.asImageBitmap(),
                srcOffset = IntOffset(
                    (sourceX - windowWidth / 2).roundToInt().coerceIn(0, bitmap.width - 1),
                    (sourceY - windowHeight / 2).roundToInt().coerceIn(0, bitmap.height - 1),
                ),
                srcSize = IntSize(
                    windowWidth.roundToInt().coerceAtMost(bitmap.width),
                    windowHeight.roundToInt().coerceAtMost(bitmap.height),
                ),
                dstOffset = IntOffset.Zero,
                dstSize = IntSize(size.width.roundToInt(), size.height.roundToInt()),
            )

            drawLine(
                AppColors.Accent,
                start = androidx.compose.ui.geometry.Offset(size.width / 2 - 12f, size.height / 2),
                end = androidx.compose.ui.geometry.Offset(size.width / 2 + 12f, size.height / 2),
                strokeWidth = 2f,
            )
            drawLine(
                AppColors.Accent,
                start = androidx.compose.ui.geometry.Offset(size.width / 2, size.height / 2 - 12f),
                end = androidx.compose.ui.geometry.Offset(size.width / 2, size.height / 2 + 12f),
                strokeWidth = 2f,
            )
        }
    }
}

@Composable
private fun StatsBar(keyframeCount: Int, pointCount: Int?, currentFrame: Int) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(AppColors.Surface)
            .padding(horizontal = 16.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.SpaceAround,
    ) {
        StatChip("$keyframeCount", "Keyframes", AppColors.Good)
        pointCount?.let { StatChip("$it", "Points", AppColors.Warning) }
        StatChip("$currentFrame", "Frame", AppColors.FlightTracker)
    }
}

@Composable
private fun StatChip(value: String, label: String, color: Color) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            value,
            color = color,
            fontWeight = FontWeight.Bold,
            style = MaterialTheme.typography.bodyMedium,
        )
        Text(label, style = MaterialTheme.typography.labelSmall, color = AppColors.Muted)
    }
}

@Composable
private fun PlaybackBar(
    positionMs: Long,
    startMs: Long,
    endMs: Long,
    isPlaying: Boolean,
    onPlayPause: () -> Unit,
    onStep: (forward: Boolean) -> Unit,
    onSeek: (Long) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(Color.Black.copy(alpha = 0.85f))
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = { onStep(false) }) {
                Icon(
                    Icons.Default.SkipPrevious,
                    contentDescription = "Previous frame",
                    tint = Color.White,
                )
            }
            IconButton(onClick = onPlayPause) {
                Icon(
                    if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                    contentDescription = if (isPlaying) "Pause" else "Play",
                    tint = Color.White,
                )
            }
            IconButton(onClick = { onStep(true) }) {
                Icon(
                    Icons.Default.SkipNext,
                    contentDescription = "Next frame",
                    tint = Color.White,
                )
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                Formatting.clock(positionMs),
                color = Color.White,
                style = MaterialTheme.typography.labelSmall,
            )
            Slider(
                value = positionMs.toFloat().coerceIn(startMs.toFloat(), endMs.toFloat().coerceAtLeast(startMs + 1f)),
                onValueChange = { onSeek(it.toLong()) },
                valueRange = startMs.toFloat()..endMs.toFloat().coerceAtLeast(startMs + 1f),
                modifier = Modifier.weight(1f),
            )
            Text(
                Formatting.clock(endMs),
                color = Color.White,
                style = MaterialTheme.typography.labelSmall,
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ActionBar(
    phase: SetupPhase,
    keyframeCount: Int,
    anchorCount: Int,
    resultSource: TrackSource?,
    isDetecting: Boolean,
    showBoxToggle: Boolean,
    boxMode: Boolean,
    onToggleBoxMode: () -> Unit,
    onContinueFromAnchoring: () -> Unit,
    onRedoAnchors: () -> Unit,
    onOpenAnchoring: () -> Unit,
    onUndo: () -> Unit,
    onProcess: () -> Unit,
    onRefine: () -> Unit,
    onAutoDetect: () -> Unit,
    onClear: () -> Unit,
    onEditPoints: () -> Unit,
    onBackToMarking: () -> Unit,
    onTargetLine: () -> Unit,
) {
    FlowRow(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
    ) {
        when (phase) {
            SetupPhase.ANCHORING -> {
                Button(onClick = onContinueFromAnchoring, enabled = anchorCount >= 2) {
                    Icon(
                        Icons.AutoMirrored.Filled.ArrowForward,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text("Continue")
                }
                if (anchorCount > 0) {
                    OutlinedButton(onClick = onRedoAnchors) {
                        Icon(
                            Icons.Default.Undo,
                            contentDescription = null,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text("Re-do")
                    }
                }
            }

            SetupPhase.MARKING -> {
                TextButton(onClick = onOpenAnchoring) {
                    Icon(
                        Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = null,
                        modifier = Modifier.size(14.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text("Anchoring")
                }
                if (showBoxToggle) {
                    OutlinedButton(
                        onClick = onToggleBoxMode,
                        colors = if (boxMode) {
                            ButtonDefaults.outlinedButtonColors(contentColor = AppColors.Warning)
                        } else {
                            ButtonDefaults.outlinedButtonColors()
                        },
                    ) {
                        Icon(
                            Icons.Default.CropFree,
                            contentDescription = null,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(if (boxMode) "Box on" else "Box")
                    }
                }
                OutlinedButton(onClick = onUndo, enabled = keyframeCount > 0) {
                    Icon(
                        Icons.Default.Undo,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text("Undo")
                }
                Button(
                    onClick = onProcess,
                    enabled = keyframeCount >= 2,
                    colors = ButtonDefaults.buttonColors(containerColor = AppColors.Good),
                ) {
                    Icon(
                        Icons.Default.AutoAwesome,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text("Process")
                }
                Button(
                    onClick = onRefine,
                    enabled = keyframeCount >= 3,
                    colors = ButtonDefaults.buttonColors(containerColor = AppColors.Roulette),
                ) {
                    Icon(
                        Icons.Default.CenterFocusStrong,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text("Auto-refine")
                }
                Button(
                    onClick = onAutoDetect,
                    enabled = !isDetecting,
                    colors = ButtonDefaults.buttonColors(containerColor = AppColors.Roulette),
                ) {
                    Icon(
                        Icons.Default.AutoFixHigh,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text("Auto-detect")
                }
                Button(
                    onClick = onClear,
                    enabled = keyframeCount > 0,
                    colors = ButtonDefaults.buttonColors(containerColor = AppColors.Bad),
                ) {
                    Icon(
                        Icons.Default.Clear,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text("Clear")
                }
            }

            SetupPhase.RESULT -> {
                if (resultSource == TrackSource.AUTO) {
                    // An automatic result has no keyframes behind it, so a plain
                    // "Edit" would drop the user into an empty marking phase.
                    Button(onClick = onEditPoints) {
                        Icon(
                            Icons.Default.EditLocationAlt,
                            contentDescription = null,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text("Edit points")
                    }
                    OutlinedButton(onClick = onAutoDetect, enabled = !isDetecting) {
                        Icon(
                            Icons.Default.Refresh,
                            contentDescription = null,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text("Re-do")
                    }
                } else {
                    OutlinedButton(onClick = onBackToMarking) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = null,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text("Edit")
                    }
                }
                OutlinedButton(onClick = onTargetLine) {
                    Icon(
                        Icons.Default.Straighten,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text("Target line")
                }
            }

            SetupPhase.CAMERA -> Unit
        }
    }
}

/**
 * The rate every tracker and the player's frame counter share.
 *
 * Ten frames a second is enough to see the disc move meaningfully between
 * samples, and cheap enough that a whole clip can be scanned in a reasonable
 * time.
 */
private const val TRACK_FPS = 10.0
