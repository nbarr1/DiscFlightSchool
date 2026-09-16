package com.discflightschool.app.ui.screens.formcoach

import android.graphics.Bitmap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.OpenWith
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.components.LoadingState
import com.discflightschool.app.ui.components.SkeletonOverlay
import com.discflightschool.app.ui.theme.AppColors
import com.discflightschool.app.video.FrameExtractor
import com.discflightschool.app.video.VideoSurface
import com.discflightschool.app.video.rememberPlaybackState
import com.discflightschool.app.video.rememberVideoPlayer
import com.discflightschool.core.geometry.Vec2
import com.discflightschool.core.math.AngleCalculator
import com.discflightschool.core.model.FormAnalysis
import kotlin.math.roundToInt

/** One step of the guided re-placement, in the order the joints are asked for. */
private data class PlacementStep(val key: String, val label: String, val side: String)

private val PLACEMENT_SEQUENCE = listOf(
    PlacementStep("PoseLandmarkType.rightShoulder", "Right shoulder", "R"),
    PlacementStep("PoseLandmarkType.leftShoulder", "Left shoulder", "L"),
    PlacementStep("PoseLandmarkType.rightElbow", "Right elbow", "R"),
    PlacementStep("PoseLandmarkType.leftElbow", "Left elbow", "L"),
    PlacementStep("PoseLandmarkType.rightWrist", "Right wrist", "R"),
    PlacementStep("PoseLandmarkType.leftWrist", "Left wrist", "L"),
    PlacementStep("PoseLandmarkType.rightHip", "Right hip", "R"),
    PlacementStep("PoseLandmarkType.leftHip", "Left hip", "L"),
    PlacementStep("PoseLandmarkType.rightKnee", "Right knee", "R"),
    PlacementStep("PoseLandmarkType.leftKnee", "Left knee", "L"),
    PlacementStep("PoseLandmarkType.rightAnkle", "Right ankle", "R"),
    PlacementStep("PoseLandmarkType.leftAnkle", "Left ankle", "L"),
)

/**
 * Hand-correction of the detected pose.
 *
 * Three ways in, because detection fails in three different ways: one joint
 * landed wrong (drag it), the whole skeleton latched onto something beside the
 * thrower (move it all), or the frame is a mess (re-place all twelve in order).
 *
 * Corrections propagate: each corrected landmark is treated as a spline anchor
 * and interpolated across the frames between corrections, so fixing the four
 * phase frames repairs the whole track rather than four isolated frames.
 */
@Composable
fun PoseCorrectionScreen(
    initialFrame: Int,
    onBack: () -> Unit,
    onApplied: () -> Unit,
) {
    val container = LocalAppContainer.current
    val workbench = container.workbench
    val density = LocalDensity.current

    val videoPath = workbench.formVideoPath
    val analysis = workbench.analysis

    if (videoPath == null || analysis == null || analysis.frames.isEmpty()) {
        Scaffold(topBar = { AppTopBar(title = "Correct pose", onBack = onBack) }) { padding ->
            LoadingState("No analysis to correct", Modifier.padding(padding))
        }
        return
    }

    val player = rememberVideoPlayer(videoPath)
    val playback = rememberPlaybackState(player)
    val startMs = workbench.analysisStartMs

    var currentFrame by remember { mutableIntStateOf(initialFrame.coerceIn(0, analysis.frames.size - 1)) }
    var videoSize by remember { mutableStateOf(Size.Zero) }
    var selectedLandmark by remember { mutableStateOf<String?>(null) }
    var moveAllMode by remember { mutableStateOf(false) }
    var sequentialMode by remember { mutableStateOf(false) }
    var sequentialStep by remember { mutableIntStateOf(0) }
    var sequentialReview by remember { mutableStateOf(false) }
    var magnifierAt by remember { mutableStateOf<Offset?>(null) }
    var frameBitmap by remember { mutableStateOf<Bitmap?>(null) }
    var revision by remember { mutableIntStateOf(0) }

    val correctedFrames = remember { mutableStateListOf<Int>() }
    val corrections = remember { mutableStateMapOf<String, MutableMap<Int, Vec2>>() }
    val sequentialPlacements = remember { mutableStateMapOf<String, Vec2>() }

    LaunchedEffect(Unit) { player.seekTo(startMs + currentFrame * FrameExtractor.POSE_INTERVAL_MS) }

    // Follow playback, except while a correction gesture owns the frame.
    LaunchedEffect(playback.positionMs) {
        if (magnifierAt != null || sequentialMode) return@LaunchedEffect
        val frame = ((playback.positionMs - startMs) / FrameExtractor.POSE_INTERVAL_MS)
            .toInt()
            .coerceIn(0, analysis.frames.size - 1)
        if (frame != currentFrame) currentFrame = frame
    }

    // The magnifier needs real pixels, which the video surface will not hand
    // back, so the frame is decoded separately while a long press is active.
    LaunchedEffect(magnifierAt != null, currentFrame) {
        if (magnifierAt == null) {
            frameBitmap?.recycle()
            frameBitmap = null
            return@LaunchedEffect
        }
        if (frameBitmap == null) {
            frameBitmap = container.frameExtractor.frameBitmapAt(
                videoPath,
                startMs + currentFrame * FrameExtractor.POSE_INTERVAL_MS,
            )
        }
    }

    fun recordCorrection(key: String, position: Vec2) {
        corrections.getOrPut(key) { mutableMapOf() }[currentFrame] = position
        if (currentFrame !in correctedFrames) correctedFrames += currentFrame
    }

    fun moveSelectedTo(canvasPosition: Offset) {
        val key = selectedLandmark ?: return
        val frame = analysis.frames[currentFrame]
        val imagePosition = SkeletonOverlay.canvasToImage(canvasPosition, videoSize, frame)
        frame.keyPoints[key] = imagePosition
        recordCorrection(key, imagePosition)
        container.postureAnalyzer.recalculateFrameAngles(frame)
        revision++
    }

    fun moveAllBy(canvasDelta: Offset) {
        val frame = analysis.frames[currentFrame]
        if (frame.keyPoints.isEmpty() || videoSize == Size.Zero) return

        // Convert the canvas delta into image space by mapping both ends of it.
        val origin = SkeletonOverlay.canvasToImage(Offset.Zero, videoSize, frame)
        val target = SkeletonOverlay.canvasToImage(canvasDelta, videoSize, frame)
        val delta = target - origin

        for (key in frame.keyPoints.keys.toList()) {
            val moved = frame.keyPoints.getValue(key) + delta
            frame.keyPoints[key] = moved
            corrections.getOrPut(key) { mutableMapOf() }[currentFrame] = moved
        }
        if (currentFrame !in correctedFrames) correctedFrames += currentFrame
        container.postureAnalyzer.recalculateFrameAngles(frame)
        revision++
    }

    fun applySequentialToFrame() {
        val frame = analysis.frames[currentFrame]
        for ((key, position) in sequentialPlacements) {
            frame.keyPoints[key] = position
            corrections.getOrPut(key) { mutableMapOf() }[currentFrame] = position
        }
        if (currentFrame !in correctedFrames) correctedFrames += currentFrame
        container.postureAnalyzer.recalculateFrameAngles(frame)
        revision++
    }

    fun onSequentialTap(canvasPosition: Offset) {
        if (sequentialStep >= PLACEMENT_SEQUENCE.size) return
        val step = PLACEMENT_SEQUENCE[sequentialStep]
        val frame = analysis.frames[currentFrame]
        sequentialPlacements[step.key] =
            SkeletonOverlay.canvasToImage(canvasPosition, videoSize, frame)

        if (sequentialStep < PLACEMENT_SEQUENCE.size - 1) {
            sequentialStep++
        } else {
            sequentialReview = true
            applySequentialToFrame()
        }
    }

    fun seekToFrame(frame: Int) {
        val clamped = frame.coerceIn(0, analysis.frames.size - 1)
        currentFrame = clamped
        player.seekTo(startMs + clamped * FrameExtractor.POSE_INTERVAL_MS)
    }

    /**
     * Interpolate every correction across the frames it spans, then recompute
     * the angles for the whole analysis.
     */
    fun applyCorrections() {
        if (corrections.isEmpty()) {
            onBack()
            return
        }

        for ((landmark, anchors) in corrections) {
            if (anchors.isEmpty()) continue
            val interpolated = AngleCalculator.interpolateAnchors(anchors)
            val first = anchors.keys.min()
            val last = anchors.keys.max()
            for (index in first..last) {
                val position = interpolated[index] ?: continue
                analysis.frames.getOrNull(index)?.keyPoints?.put(landmark, position)
            }
        }

        for (frame in analysis.frames) {
            container.postureAnalyzer.recalculateFrameAngles(frame)
        }

        workbench.analysis = FormAnalysis(
            id = analysis.id,
            date = analysis.date,
            videoPath = analysis.videoPath,
            frames = analysis.frames,
            score = analysis.score,
            isMock = analysis.isMock,
            failureReason = analysis.failureReason,
        )
        onApplied()
    }

    Scaffold(
        topBar = {
            AppTopBar(title = "Correct pose", onBack = onBack) {
                if (!sequentialMode) {
                    TextButton(onClick = { applyCorrections() }) {
                        Icon(
                            Icons.Default.Check,
                            contentDescription = null,
                            tint = AppColors.Good,
                        )
                        Spacer(Modifier.width(4.dp))
                        Text(
                            if (corrections.isEmpty()) {
                                "Done"
                            } else {
                                "Apply (${correctedFrames.size})"
                            },
                            color = AppColors.Good,
                        )
                    }
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
                    .weight(1f)
                    .fillMaxWidth()
                    .background(Color.Black)
                    .onSizeChanged {
                        videoSize = Size(it.width.toFloat(), it.height.toFloat())
                    }
                    .pointerInput(sequentialMode, sequentialReview, currentFrame) {
                        detectTapGestures(
                            onTap = { position ->
                                val frame = analysis.frames[currentFrame]
                                if (sequentialMode && !sequentialReview) {
                                    onSequentialTap(position)
                                } else {
                                    selectedLandmark = SkeletonOverlay.nearestLandmark(
                                        position,
                                        videoSize,
                                        frame,
                                    )
                                }
                            },
                            onLongPress = { position ->
                                if (sequentialMode) return@detectTapGestures
                                player.pause()
                                selectedLandmark = SkeletonOverlay.nearestLandmark(
                                    position,
                                    videoSize,
                                    analysis.frames[currentFrame],
                                )
                                magnifierAt = position
                            },
                        )
                    }
                    .pointerInput(moveAllMode, sequentialMode, currentFrame) {
                        detectDragGestures(
                            onDragEnd = { magnifierAt = null },
                            onDragCancel = { magnifierAt = null },
                        ) { change, dragAmount ->
                            change.consume()
                            if (sequentialMode) return@detectDragGestures
                            if (moveAllMode) {
                                moveAllBy(dragAmount)
                            } else {
                                if (magnifierAt != null) magnifierAt = change.position
                                moveSelectedTo(change.position)
                            }
                        }
                    },
            ) {
                VideoSurface(player, Modifier.fillMaxSize())

                // Landmarks are edited in place, so `revision` is what tells
                // the composition that this frame's contents changed.
                val frame = remember(currentFrame, revision) { analysis.frames[currentFrame] }
                Canvas(Modifier.fillMaxSize()) {
                    with(SkeletonOverlay) {
                        if (!sequentialMode || sequentialReview) {
                            drawSkeleton(
                                frame = frame,
                                interactive = true,
                                selectedLandmark = selectedLandmark,
                            )
                        }
                    }

                    if (sequentialMode) {
                        for ((key, position) in sequentialPlacements) {
                            val center = SkeletonOverlay.scalePoint(position, size, frame)
                            drawCircle(AppColors.Good, radius = 7.dp.toPx(), center = center)
                            drawCircle(
                                Color.White,
                                radius = 7.dp.toPx(),
                                center = center,
                                style = Stroke(width = 2.dp.toPx()),
                            )
                        }
                    }
                }

                val magnifier = magnifierAt
                val bitmap = frameBitmap
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
            }

            if (sequentialMode) {
                SequentialBanner(
                    step = sequentialStep,
                    isReview = sequentialReview,
                    placements = sequentialPlacements.keys,
                    onRedoStep = { index ->
                        sequentialStep = index
                        sequentialReview = false
                        for (i in index until PLACEMENT_SEQUENCE.size) {
                            sequentialPlacements.remove(PLACEMENT_SEQUENCE[i].key)
                        }
                    },
                    onCommit = {
                        applySequentialToFrame()
                        sequentialMode = false
                        sequentialReview = false
                        sequentialPlacements.clear()
                    },
                    onCancel = {
                        sequentialMode = false
                        sequentialReview = false
                        sequentialPlacements.clear()
                    },
                )
            } else {
                FrameScrubber(
                    currentFrame = currentFrame,
                    frameCount = analysis.frames.size,
                    correctedFrames = correctedFrames,
                    onSeek = { seekToFrame(it) },
                )

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(onClick = { seekToFrame(currentFrame - 1) }) {
                        Icon(Icons.Default.SkipPrevious, contentDescription = "Previous frame")
                    }
                    IconButton(onClick = { seekToFrame(currentFrame + 1) }) {
                        Icon(Icons.Default.SkipNext, contentDescription = "Next frame")
                    }
                    FilterChip(
                        selected = moveAllMode,
                        onClick = { moveAllMode = !moveAllMode },
                        label = { Text("Move all") },
                        leadingIcon = {
                            Icon(
                                Icons.Default.OpenWith,
                                contentDescription = null,
                                modifier = Modifier.size(16.dp),
                            )
                        },
                    )
                    OutlinedButton(
                        onClick = {
                            player.pause()
                            sequentialMode = true
                            sequentialStep = 0
                            sequentialReview = false
                            sequentialPlacements.clear()
                            moveAllMode = false
                            selectedLandmark = null
                        },
                    ) {
                        Icon(
                            Icons.Default.Refresh,
                            contentDescription = null,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text("Re-place all")
                    }
                }

                Text(
                    text = when {
                        moveAllMode ->
                            "Drag anywhere to move the whole skeleton onto the thrower."
                        selectedLandmark != null ->
                            "Dragging ${landmarkLabel(selectedLandmark!!)}. " +
                                "Long-press for a magnified view."
                        else ->
                            "Tap a joint to select it, then drag to correct it. " +
                                "Long-press to zoom."
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    style = MaterialTheme.typography.labelMedium,
                    color = AppColors.Muted,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

@Composable
private fun Magnifier(
    bitmap: Bitmap,
    focus: Offset,
    canvasSize: Size,
    offsetPx: IntOffset,
) {
    val zoom = 2.5f
    Box(
        modifier = Modifier
            .offset { offsetPx }
            .size(140.dp)
            .background(Color.Black, CircleShape)
            .border(2.dp, AppColors.Accent, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.fillMaxSize()) {
            if (canvasSize == Size.Zero) return@Canvas

            // The focus point in bitmap pixels, then a window around it.
            val sourceX = (focus.x / canvasSize.width) * bitmap.width
            val sourceY = (focus.y / canvasSize.height) * bitmap.height
            val windowWidth = size.width / zoom
            val windowHeight = size.height / zoom

            val image = bitmap.asImageBitmap()
            drawImage(
                image = image,
                srcOffset = IntOffset(
                    (sourceX - windowWidth / 2).roundToInt().coerceIn(0, bitmap.width - 1),
                    (sourceY - windowHeight / 2).roundToInt().coerceIn(0, bitmap.height - 1),
                ),
                srcSize = IntSize(
                    windowWidth.roundToInt().coerceAtMost(bitmap.width),
                    windowHeight.roundToInt().coerceAtMost(bitmap.height),
                ),
                dstOffset = IntOffset.Zero,
                dstSize = IntSize(
                    size.width.roundToInt(),
                    size.height.roundToInt(),
                ),
            )

            // Crosshair at the exact point being placed.
            drawLine(
                AppColors.Accent,
                start = Offset(size.width / 2 - 12f, size.height / 2),
                end = Offset(size.width / 2 + 12f, size.height / 2),
                strokeWidth = 2f,
            )
            drawLine(
                AppColors.Accent,
                start = Offset(size.width / 2, size.height / 2 - 12f),
                end = Offset(size.width / 2, size.height / 2 + 12f),
                strokeWidth = 2f,
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SequentialBanner(
    step: Int,
    isReview: Boolean,
    placements: Set<String>,
    onRedoStep: (Int) -> Unit,
    onCommit: () -> Unit,
    onCancel: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(AppColors.Surface)
            .padding(16.dp),
    ) {
        if (!isReview) {
            val current = PLACEMENT_SEQUENCE[step]
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Default.TouchApp,
                    contentDescription = null,
                    tint = AppColors.Accent,
                )
                Spacer(Modifier.width(8.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        "Tap the ${current.label.lowercase()}",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                    )
                    Text(
                        "Step ${step + 1} of ${PLACEMENT_SEQUENCE.size} · " +
                            "${current.side} side, as you see it on screen",
                        style = MaterialTheme.typography.labelMedium,
                        color = AppColors.Muted,
                    )
                }
                TextButton(onClick = onCancel) { Text("Cancel") }
            }
        } else {
            Text(
                "Review the placements",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                "Tap a joint below to place it again, or keep these positions.",
                style = MaterialTheme.typography.labelMedium,
                color = AppColors.Muted,
            )
            Spacer(Modifier.height(8.dp))
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                PLACEMENT_SEQUENCE.forEachIndexed { index, placement ->
                    AssistChip(
                        onClick = { onRedoStep(index) },
                        label = {
                            Text(placement.label, style = MaterialTheme.typography.labelSmall)
                        },
                        leadingIcon = if (placement.key in placements) {
                            {
                                Icon(
                                    Icons.Default.Check,
                                    contentDescription = null,
                                    tint = AppColors.Good,
                                    modifier = Modifier.size(14.dp),
                                )
                            }
                        } else {
                            null
                        },
                    )
                }
            }
            Spacer(Modifier.height(12.dp))
            Row {
                OutlinedButton(onClick = onCancel, modifier = Modifier.weight(1f)) {
                    Text("Discard")
                }
                Spacer(Modifier.width(12.dp))
                Button(onClick = onCommit, modifier = Modifier.weight(1f)) {
                    Text("Keep placements")
                }
            }
        }
    }
}

/** The frame strip, with a tick on every frame the user has corrected. */
@Composable
private fun FrameScrubber(
    currentFrame: Int,
    frameCount: Int,
    correctedFrames: List<Int>,
    onSeek: (Int) -> Unit,
) {
    Column(Modifier.padding(horizontal = 16.dp)) {
        Canvas(
            Modifier
                .fillMaxWidth()
                .height(12.dp),
        ) {
            if (frameCount <= 1) return@Canvas
            for (frame in correctedFrames) {
                val x = (frame.toFloat() / (frameCount - 1)) * size.width
                drawLine(
                    color = AppColors.Good,
                    start = Offset(x, 0f),
                    end = Offset(x, size.height),
                    strokeWidth = 2f,
                )
            }
        }
        Slider(
            value = currentFrame.toFloat(),
            onValueChange = { onSeek(it.roundToInt()) },
            valueRange = 0f..(frameCount - 1).coerceAtLeast(1).toFloat(),
        )
        Text(
            "Frame ${currentFrame + 1} / $frameCount · ${correctedFrames.size} corrected",
            style = MaterialTheme.typography.labelSmall,
            color = AppColors.Muted,
            modifier = Modifier.fillMaxWidth(),
            textAlign = TextAlign.Center,
        )
    }
}

private fun landmarkLabel(key: String): String = key
    .removePrefix("PoseLandmarkType.")
    .replace(Regex("([A-Z])"), " $1")
    .trim()
    .lowercase()
