package com.discflightschool.app.ui.screens.formcoach

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Analytics
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CompareArrows
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PersonSearch
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Straighten
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.ui.Formatting
import com.discflightschool.app.ui.components.AngleWaveform
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.components.LoadingState
import com.discflightschool.app.ui.components.PhaseMarker
import com.discflightschool.app.ui.components.SectionCard
import com.discflightschool.app.ui.components.SkeletonCanvas
import com.discflightschool.app.ui.components.frameForFraction
import com.discflightschool.app.ui.theme.AppColors
import com.discflightschool.app.video.FrameExtractor
import com.discflightschool.app.video.VideoSurface
import com.discflightschool.app.video.rememberPlaybackState
import com.discflightschool.app.video.rememberVideoPlayer
import com.discflightschool.core.baseline.ProBaselineDatabase
import com.discflightschool.core.model.FormSessionRecord
import com.discflightschool.core.model.ThrowTypes
import com.discflightschool.core.posture.FormSuggestion
import com.discflightschool.core.posture.FormSuggestions
import com.discflightschool.core.posture.PostureMath
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

/**
 * The result of a form analysis: the throw with its skeleton drawn on, how it
 * scored against a pro, and what to work on.
 *
 * Phase verification runs first when the user marked phases. The score depends
 * on the landmarks being right, so the frames that matter most get checked — and
 * corrected — before any number is presented as a measurement.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PostureAnalysisScreen(
    onBack: () -> Unit,
    onOpenPhaseComparison: () -> Unit,
    onOpenPoseCorrection: (initialFrame: Int) -> Unit,
    onOpenArticle: (String) -> Unit,
) {
    val container = LocalAppContainer.current
    val workbench = container.workbench
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }

    val videoPath = workbench.formVideoPath
    if (videoPath == null) {
        Scaffold(topBar = { AppTopBar(title = "Form analysis", onBack = onBack) }) { padding ->
            LoadingState("No video selected", Modifier.padding(padding))
        }
        return
    }

    var isAnalyzing by remember { mutableStateOf(workbench.analysis == null) }
    var analysisProgress by remember { mutableStateOf(0f) }
    var showSkeleton by remember { mutableStateOf(true) }
    var showThresholds by remember { mutableStateOf(true) }
    var currentFrame by remember { mutableIntStateOf(0) }
    var proMenuExpanded by remember { mutableStateOf(false) }
    var players by remember { mutableStateOf<List<String>>(emptyList()) }
    var deviationScore by remember { mutableStateOf<Double?>(null) }
    var suggestions by remember { mutableStateOf<List<FormSuggestion>>(emptyList()) }
    var verificationIndex by remember { mutableIntStateOf(-1) }

    val player = rememberVideoPlayer(videoPath)
    val playback = rememberPlaybackState(player)
    val analysis = workbench.analysis

    val startMs = workbench.analysisStartMs
    val sortedPhases = remember(workbench.phaseFrameIndices) {
        workbench.phaseFrameIndices.entries.sortedBy { it.value }
    }

    /** Recompute the score and the coaching cues from the current analysis. */
    suspend fun refreshDerived() {
        val current = workbench.analysis ?: return
        val database = container.proBaselineRepository.database()
        val pro = workbench.proPlayer

        if (database != null && pro != null) {
            val resolved = database.phaseAnglesWithFallback(pro, workbench.throwType)
            workbench.proPhaseAngles = resolved.angles
            workbench.proDataWarnings = resolved.qualityWarnings
            deviationScore = PostureMath.computeProDeviationScore(
                frames = current.frames,
                phaseAngles = resolved.angles,
                throwType = workbench.throwType,
                phaseFrameIndices = workbench.phaseFrameIndices.ifEmpty { null },
            )
        } else {
            workbench.proPhaseAngles = emptyMap()
            workbench.proDataWarnings = emptyList()
            deviationScore = null
        }

        suggestions = FormSuggestions.generate(
            frames = current.frames,
            baseline = database,
            throwType = workbench.throwType,
            proPhaseAngles = workbench.proPhaseAngles.ifEmpty { null },
            phaseFrameIndices = workbench.phaseFrameIndices.ifEmpty { null },
            proName = workbench.proPlayer,
        )
    }

    LaunchedEffect(Unit) {
        container.proBaselineRepository.database()?.let { players = it.playerNames }
        container.knowledgeBaseRepository.load()

        if (workbench.analysis == null) {
            isAnalyzing = true
            val result = container.postureAnalyzer.analyzeForm(
                videoPath = videoPath,
                cacheDir = container.trainingDataDir.parentFile ?: container.trainingDataDir,
                startMs = startMs,
                frameCount = workbench.analysisFrameCount.takeIf { it > 0 } ?: 30,
                isLeftHanded = workbench.isLeftHanded,
                throwType = workbench.throwType,
                onProgress = { analysisProgress = it },
            )
            workbench.analysis = result
            isAnalyzing = false

            refreshDerived()

            // Save the session only once the real deviation score exists: the
            // analysis itself carries a placeholder score.
            if (!result.isMock) {
                container.formHistoryRepository.saveSession(
                    FormSessionRecord(
                        id = result.id,
                        date = result.date,
                        score = deviationScore ?: result.score,
                        throwType = workbench.throwType,
                        proPlayer = workbench.proPlayer,
                        frameCount = result.frames.size,
                        avgAngles = PostureMath.averageAngles(result.frames),
                    ),
                )
            }

            if (workbench.phaseFrameIndices.isNotEmpty()) {
                verificationIndex = 0
                currentFrame = sortedPhases.first().value
                player.seekTo(
                    startMs + sortedPhases.first().value * FrameExtractor.POSE_INTERVAL_MS,
                )
            } else {
                player.seekTo(startMs)
            }
        } else {
            refreshDerived()
            player.seekTo(startMs)
        }
    }

    // Keep the skeleton in step with playback.
    LaunchedEffect(playback.positionMs, analysis) {
        val frames = analysis?.frames ?: return@LaunchedEffect
        if (frames.isEmpty()) return@LaunchedEffect
        if (playback.positionMs < startMs) return@LaunchedEffect
        val frame = ((playback.positionMs - startMs) / FrameExtractor.POSE_INTERVAL_MS)
            .toInt()
            .coerceIn(0, frames.size - 1)
        if (frame != currentFrame) currentFrame = frame
    }

    fun seekToFrame(frame: Int) {
        val frames = analysis?.frames ?: return
        val clamped = frame.coerceIn(0, (frames.size - 1).coerceAtLeast(0))
        currentFrame = clamped
        player.seekTo(startMs + clamped * FrameExtractor.POSE_INTERVAL_MS)
    }

    Scaffold(
        topBar = {
            AppTopBar(title = "Form analysis", onBack = onBack) {
                if (analysis != null) {
                    IconButton(onClick = { showSkeleton = !showSkeleton }) {
                        Icon(
                            if (showSkeleton) Icons.Default.Visibility else Icons.Default.VisibilityOff,
                            contentDescription = if (showSkeleton) {
                                "Hide skeleton"
                            } else {
                                "Show skeleton"
                            },
                        )
                    }
                    IconButton(onClick = { showThresholds = !showThresholds }) {
                        Icon(
                            Icons.Default.Straighten,
                            contentDescription = if (showThresholds) {
                                "Hide pro markers"
                            } else {
                                "Show pro markers"
                            },
                            tint = if (showThresholds) AppColors.Accent else AppColors.Muted,
                        )
                    }
                }
            }
        },
        snackbarHost = { SnackbarHost(snackbarHostState) },
    ) { padding ->
        if (isAnalyzing) {
            Column(
                modifier = Modifier
                    .padding(padding)
                    .fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                CircularProgressIndicator(progress = { analysisProgress })
                Spacer(Modifier.height(16.dp))
                Text("Analyzing your form...")
                Spacer(Modifier.height(8.dp))
                Text(
                    "Detecting pose and calculating joint angles",
                    style = MaterialTheme.typography.bodySmall,
                    color = AppColors.Muted,
                )
            }
            return@Scaffold
        }

        if (analysis == null) {
            LoadingState("No analysis available", Modifier.padding(padding))
            return@Scaffold
        }

        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize()
                .verticalScroll(rememberScrollState()),
        ) {
            if (analysis.isMock) {
                MockWarning(analysis.failureReason)
            }

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(9f / 16f)
                    .background(Color.Black),
            ) {
                VideoSurface(player, Modifier.fillMaxSize())
                val frame = analysis.frames.getOrNull(currentFrame)
                if (showSkeleton && frame != null && frame.keyPoints.isNotEmpty()) {
                    SkeletonCanvas(frame = frame, modifier = Modifier.fillMaxSize())
                }
            }

            if (verificationIndex in sortedPhases.indices) {
                PhaseVerificationCard(
                    phaseName = sortedPhases[verificationIndex].key,
                    index = verificationIndex,
                    total = sortedPhases.size,
                    onFix = { onOpenPoseCorrection(sortedPhases[verificationIndex].value) },
                    onApprove = {
                        val next = verificationIndex + 1
                        if (next < sortedPhases.size) {
                            verificationIndex = next
                            seekToFrame(sortedPhases[next].value)
                        } else {
                            verificationIndex = -1
                            scope.launch { snackbarHostState.showSnackbar("All phases verified") }
                        }
                    },
                )
            }

            PlaybackControls(
                positionMs = playback.positionMs,
                durationMs = playback.durationMs,
                isPlaying = playback.isPlaying,
                frameLabel = "Frame ${currentFrame + 1} / ${analysis.frames.size}",
                onStepBack = { seekToFrame(currentFrame - 1) },
                onStepForward = { seekToFrame(currentFrame + 1) },
                onPlayPause = { if (playback.isPlaying) player.pause() else player.play() },
                onSeek = { player.seekTo(it) },
            )

            ScoreCard(
                score = deviationScore,
                proName = workbench.proPlayer,
                throwType = workbench.throwType,
            )

            SectionCard(
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                title = "Compare with a pro",
                accent = AppColors.FormCoach,
            ) {
                Column {
                    ExposedDropdownMenuBox(
                        expanded = proMenuExpanded,
                        onExpandedChange = { proMenuExpanded = it },
                    ) {
                        OutlinedTextField(
                            value = workbench.proPlayer ?: "None",
                            onValueChange = {},
                            readOnly = true,
                            label = { Text("Pro player") },
                            trailingIcon = {
                                ExposedDropdownMenuDefaults.TrailingIcon(proMenuExpanded)
                            },
                            modifier = Modifier
                                .fillMaxWidth()
                                .menuAnchor(),
                        )
                        ExposedDropdownMenu(
                            expanded = proMenuExpanded,
                            onDismissRequest = { proMenuExpanded = false },
                        ) {
                            DropdownMenuItem(
                                text = { Text("None") },
                                onClick = {
                                    workbench.proPlayer = null
                                    proMenuExpanded = false
                                    scope.launch { refreshDerived() }
                                },
                            )
                            players.forEach { player ->
                                DropdownMenuItem(
                                    text = { Text(player) },
                                    onClick = {
                                        workbench.proPlayer = player
                                        proMenuExpanded = false
                                        scope.launch { refreshDerived() }
                                    },
                                )
                            }
                        }
                    }

                    Spacer(Modifier.height(12.dp))

                    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                        SegmentedButton(
                            selected = workbench.throwType == ThrowTypes.BACKHAND,
                            onClick = {
                                workbench.throwType = ThrowTypes.BACKHAND
                                scope.launch { refreshDerived() }
                            },
                            shape = SegmentedButtonDefaults.itemShape(index = 0, count = 2),
                        ) {
                            Text("Backhand")
                        }
                        SegmentedButton(
                            selected = workbench.throwType == ThrowTypes.FOREHAND,
                            onClick = {
                                workbench.throwType = ThrowTypes.FOREHAND
                                scope.launch { refreshDerived() }
                            },
                            shape = SegmentedButtonDefaults.itemShape(index = 1, count = 2),
                        ) {
                            Text("Forehand")
                        }
                    }
                }
            }

            if (workbench.proDataWarnings.isNotEmpty()) {
                QualityWarnings(workbench.proDataWarnings)
            }

            val phases = ProBaselineDatabase.phaseNames(workbench.throwType)
            val hasAllPhases = phases.all { it in workbench.phaseFrameIndices }
            if (workbench.proPlayer != null && hasAllPhases) {
                Button(
                    onClick = onOpenPhaseComparison,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                ) {
                    Icon(Icons.Default.CompareArrows, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text("Compare phases vs pro")
                }
            }

            OutlinedButton(
                onClick = { onOpenPoseCorrection(currentFrame) },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp),
            ) {
                Icon(Icons.Default.Edit, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Correct the pose by hand")
            }

            AngleCharts(
                analysis = analysis,
                currentFrame = currentFrame,
                phaseMarkers = if (showThresholds) {
                    phaseMarkersFor(
                        angleKeys = analysis.frames.firstOrNull()?.angles?.keys.orEmpty(),
                        proPhaseAngles = workbench.proPhaseAngles,
                        phaseFrameIndices = workbench.phaseFrameIndices,
                        phases = phases,
                        frameCount = analysis.frames.size,
                    )
                } else {
                    emptyMap()
                },
                onSeekToFrame = { seekToFrame(it) },
            )

            Suggestions(
                suggestions = suggestions,
                onOpenArticle = onOpenArticle,
                knownArticleIds = container.knowledgeBaseRepository.articles.map { it.id }.toSet(),
            )

            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun MockWarning(reason: String?) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, top = 12.dp, end = 16.dp)
            .background(AppColors.Bad.copy(alpha = 0.18f), RoundedCornerShape(8.dp))
            .border(1.5.dp, AppColors.Bad, RoundedCornerShape(8.dp))
            .padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Icon(
                Icons.Default.WarningAmber,
                contentDescription = null,
                tint = AppColors.Warning,
                modifier = Modifier.size(22.dp),
            )
            Spacer(Modifier.width(10.dp))
            Column {
                Text("Analysis unavailable", fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(4.dp))
                Text(
                    reason ?: "No person was detected. Try recording from the side with " +
                        "good lighting.",
                    style = MaterialTheme.typography.bodySmall,
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    "The angles and score below are simulated placeholders, not measurements " +
                        "of your throw.",
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}

@Composable
private fun QualityWarnings(warnings: List<String>) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .background(AppColors.Warning.copy(alpha = 0.14f), RoundedCornerShape(8.dp))
            .border(1.dp, AppColors.Warning, RoundedCornerShape(8.dp))
            .padding(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Outlined.Info,
                contentDescription = null,
                tint = AppColors.Warning,
                modifier = Modifier.size(16.dp),
            )
            Spacer(Modifier.width(6.dp))
            Text(
                "Reference data notes",
                color = AppColors.Warning,
                fontWeight = FontWeight.Bold,
                style = MaterialTheme.typography.labelLarge,
            )
        }
        Spacer(Modifier.height(6.dp))
        warnings.take(3).forEach { warning ->
            Text(
                "• $warning",
                style = MaterialTheme.typography.labelSmall,
                color = AppColors.Warning,
                modifier = Modifier.padding(top = 3.dp),
            )
        }
    }
}

@Composable
private fun PhaseVerificationCard(
    phaseName: String,
    index: Int,
    total: Int,
    onFix: () -> Unit,
    onApprove: () -> Unit,
) {
    SectionCard(
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        accent = AppColors.FlightTracker,
    ) {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Default.Check,
                    contentDescription = null,
                    tint = AppColors.FlightTracker,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    "Verify phase: ${Formatting.phaseLabel(phaseName)}",
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.weight(1f),
                )
                Row {
                    repeat(total) { i ->
                        Box(
                            modifier = Modifier
                                .padding(start = 4.dp)
                                .size(8.dp)
                                .background(
                                    when {
                                        i < index -> AppColors.Good
                                        i == index -> Color.White
                                        else -> AppColors.Muted
                                    },
                                    CircleShape,
                                ),
                        )
                    }
                }
            }
            Spacer(Modifier.height(6.dp))
            Text(
                "Is the pose overlay correct for this frame?",
                style = MaterialTheme.typography.bodySmall,
                color = AppColors.Muted,
            )
            Spacer(Modifier.height(10.dp))
            Row {
                OutlinedButton(onClick = onFix, modifier = Modifier.weight(1f)) {
                    Icon(
                        Icons.Default.Edit,
                        contentDescription = null,
                        tint = AppColors.Warning,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text("Fix it", color = AppColors.Warning)
                }
                Spacer(Modifier.width(12.dp))
                Button(onClick = onApprove, modifier = Modifier.weight(1f)) {
                    Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Looks good")
                }
            }
        }
    }
}

@Composable
private fun PlaybackControls(
    positionMs: Long,
    durationMs: Long,
    isPlaying: Boolean,
    frameLabel: String,
    onStepBack: () -> Unit,
    onStepForward: () -> Unit,
    onPlayPause: () -> Unit,
    onSeek: (Long) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(Color.Black.copy(alpha = 0.85f))
            .padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onStepBack) {
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
            IconButton(onClick = onStepForward) {
                Icon(
                    Icons.Default.SkipNext,
                    contentDescription = "Next frame",
                    tint = Color.White,
                )
            }
            Slider(
                value = positionMs.toFloat().coerceIn(0f, durationMs.toFloat().coerceAtLeast(1f)),
                onValueChange = { onSeek(it.toLong()) },
                valueRange = 0f..durationMs.toFloat().coerceAtLeast(1f),
                modifier = Modifier.weight(1f),
            )
            Text(
                "${Formatting.clock(positionMs)} / ${Formatting.clock(durationMs)}",
                style = MaterialTheme.typography.labelSmall,
                color = Color.White,
            )
        }
        Text(frameLabel, style = MaterialTheme.typography.labelSmall, color = AppColors.Muted)
    }
}

@Composable
private fun ScoreCard(score: Double?, proName: String?, throwType: String) {
    SectionCard(modifier = Modifier.padding(16.dp)) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                "Pro deviation score",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(12.dp))

            if (score != null) {
                Box(contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(
                        progress = { (score / 100).toFloat() },
                        strokeWidth = 10.dp,
                        color = Formatting.scoreColor(score),
                        trackColor = AppColors.Surface,
                        modifier = Modifier.size(120.dp),
                    )
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(
                            Formatting.decimal(score),
                            style = MaterialTheme.typography.headlineMedium,
                            fontWeight = FontWeight.Bold,
                            color = Formatting.scoreColor(score),
                        )
                        Text(
                            scoreLabel(score),
                            style = MaterialTheme.typography.labelSmall,
                            color = Formatting.scoreColor(score),
                        )
                    }
                }
                Spacer(Modifier.height(8.dp))
                Text(
                    "vs ${proName ?: "pro"} · $throwType",
                    style = MaterialTheme.typography.labelMedium,
                    color = AppColors.Muted,
                )
            } else {
                Icon(
                    Icons.Default.PersonSearch,
                    contentDescription = null,
                    tint = AppColors.Muted,
                    modifier = Modifier.size(48.dp),
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    "Select a pro to score your form",
                    style = MaterialTheme.typography.bodySmall,
                    color = AppColors.Muted,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

@Composable
private fun AngleCharts(
    analysis: com.discflightschool.core.model.FormAnalysis,
    currentFrame: Int,
    phaseMarkers: Map<String, List<PhaseMarker>>,
    onSeekToFrame: (Int) -> Unit,
) {
    val angleKeys = analysis.frames.firstOrNull()?.angles?.keys?.toList().orEmpty()
    if (angleKeys.isEmpty()) {
        Text(
            "No frame data available",
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            textAlign = TextAlign.Center,
            color = AppColors.Muted,
        )
        return
    }

    angleKeys.forEach { angleKey ->
        val data = analysis.frames.map { it.angles[angleKey] ?: 0.0 }
        SectionCard(modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
            Column {
                Text(
                    Formatting.angleLabel(angleKey),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold,
                )
                Spacer(Modifier.height(8.dp))
                AngleWaveform(
                    angleData = data,
                    currentFrame = currentFrame,
                    phaseMarkers = phaseMarkers[angleKey].orEmpty(),
                    onSeekToFraction = { fraction ->
                        onSeekToFrame(frameForFraction(fraction, data.size))
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(80.dp),
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    "Current: ${Formatting.degrees(data[currentFrame.coerceIn(0, data.size - 1)])}",
                    style = MaterialTheme.typography.bodySmall,
                    color = AppColors.Muted,
                )
            }
        }
    }
}

@Composable
private fun Suggestions(
    suggestions: List<FormSuggestion>,
    knownArticleIds: Set<String>,
    onOpenArticle: (String) -> Unit,
) {
    SectionCard(
        modifier = Modifier.padding(16.dp),
        title = "Suggestions",
        accent = AppColors.FlightTracker,
    ) {
        Column {
            if (suggestions.isEmpty()) {
                Text(
                    "Analyzing...",
                    style = MaterialTheme.typography.bodySmall,
                    color = AppColors.Muted,
                )
                return@Column
            }
            suggestions.forEach { suggestion ->
                Row(
                    modifier = Modifier.padding(bottom = 4.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Icon(
                        Icons.Default.Lightbulb,
                        contentDescription = null,
                        tint = AppColors.Warning,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(suggestion.text, style = MaterialTheme.typography.bodySmall)
                }
                val articleId = suggestion.kbArticleId
                if (articleId != null && articleId in knownArticleIds) {
                    Text(
                        "Learn more →",
                        style = MaterialTheme.typography.labelSmall,
                        color = AppColors.Accent,
                        modifier = Modifier
                            .padding(start = 24.dp, bottom = 10.dp)
                            .clickable { onOpenArticle(articleId) },
                    )
                } else {
                    Spacer(Modifier.height(6.dp))
                }
            }
        }
    }
}

/** Where each pro phase angle sits on a given angle's waveform. */
private fun phaseMarkersFor(
    angleKeys: Set<String>,
    proPhaseAngles: Map<String, Map<String, Double>>,
    phaseFrameIndices: Map<String, Int>,
    phases: List<String>,
    frameCount: Int,
): Map<String, List<PhaseMarker>> {
    if (proPhaseAngles.isEmpty() || frameCount == 0) return emptyMap()

    val indices = phaseFrameIndices.ifEmpty { evenlySpacedPhaseIndices(frameCount, phases) }

    return angleKeys.associateWith { angleKey ->
        phases.mapNotNull { phase ->
            val angle = proPhaseAngles[phase]?.get(angleKey) ?: return@mapNotNull null
            val frameIndex = indices[phase] ?: return@mapNotNull null
            PhaseMarker(
                t = if (frameCount > 1) frameIndex.toDouble() / (frameCount - 1) else 0.0,
                angle = angle,
                label = phaseShortLabel(phase),
            )
        }
    }.filterValues { it.isNotEmpty() }
}

/** The fallback when the user never marked the phases. */
private fun evenlySpacedPhaseIndices(frameCount: Int, phases: List<String>): Map<String, Int> {
    val fractions = listOf(0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0)
    return phases.mapIndexedNotNull { index, phase ->
        val fraction = fractions.getOrNull(index) ?: return@mapIndexedNotNull null
        phase to (fraction * (frameCount - 1)).roundToInt().coerceIn(0, frameCount - 1)
    }.toMap()
}

private fun phaseShortLabel(phase: String): String = when (phase) {
    "reach_back" -> "RB"
    "wind_up" -> "WU"
    "power_pocket" -> "PP"
    "release" -> "Rel"
    "follow_through" -> "FT"
    else -> phase.take(2).uppercase()
}

private fun scoreLabel(score: Double): String = when {
    score >= 90 -> "Excellent"
    score >= 80 -> "Good"
    score >= 70 -> "Fair"
    score >= 60 -> "Needs work"
    else -> "Poor"
}
