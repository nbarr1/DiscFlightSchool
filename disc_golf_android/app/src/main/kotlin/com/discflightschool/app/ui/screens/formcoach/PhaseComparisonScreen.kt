package com.discflightschool.app.ui.screens.formcoach

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.ui.Formatting
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.components.LoadingState
import com.discflightschool.app.ui.components.SectionCard
import com.discflightschool.app.ui.theme.AppColors
import com.discflightschool.core.baseline.ProBaselineDatabase
import com.discflightschool.core.model.FormFrame
import kotlin.math.abs

/**
 * The user's angles against the pro's, phase by phase.
 *
 * Only the four measured phase snapshots are compared. A frame-by-frame
 * comparison would need per-frame pro data that does not exist; interpolating
 * between snapshots would produce an invented reference to score against.
 */
@Composable
fun PhaseComparisonScreen(onBack: () -> Unit) {
    val container = LocalAppContainer.current
    val workbench = container.workbench

    val analysis = workbench.analysis
    val proName = workbench.proPlayer
    val phaseFrames = workbench.phaseFrameIndices

    var proPhaseAngles by remember { mutableStateOf<Map<String, Map<String, Double>>?>(null) }
    val expanded = remember { mutableStateMapOf<String, Boolean>() }

    LaunchedEffect(proName, workbench.throwType) {
        val database = container.proBaselineRepository.database()
        proPhaseAngles = if (database != null && proName != null) {
            database.phaseAnglesWithFallback(proName, workbench.throwType).angles
        } else {
            emptyMap()
        }
    }

    Scaffold(
        topBar = { AppTopBar(title = "vs ${proName ?: "pro"}", onBack = onBack) },
    ) { padding ->
        val angles = proPhaseAngles
        if (analysis == null || angles == null) {
            LoadingState("Loading pro data...", Modifier.padding(padding))
            return@Scaffold
        }

        val phases = ProBaselineDatabase.phaseNames(workbench.throwType)
        val comparisons = phases.mapNotNull { phase ->
            val frameIndex = phaseFrames[phase] ?: return@mapNotNull null
            val userFrame = analysis.frames.getOrNull(frameIndex) ?: return@mapNotNull null
            phase to comparePhase(userFrame, angles[phase].orEmpty())
        }

        LazyColumn(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize(),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                OverallScoreCard(comparisons.map { it.second })
            }

            items(comparisons.size) { index ->
                val (phase, rows) = comparisons[index]
                PhaseCard(
                    phase = phase,
                    rows = rows,
                    expanded = expanded[phase] ?: true,
                    onToggle = { expanded[phase] = !(expanded[phase] ?: true) },
                )
            }
        }
    }
}

/** One angle, as measured and as the pro throws it. */
private data class AngleComparison(
    val angleKey: String,
    val userAngle: Double,
    val proAngle: Double,
) {
    val difference: Double get() = abs(userAngle - proAngle)
}

private fun comparePhase(
    userFrame: FormFrame,
    proAngles: Map<String, Double>,
): List<AngleComparison> = proAngles.mapNotNull { (angleKey, proAngle) ->
    val userAngle = userFrame.angles[angleKey] ?: return@mapNotNull null
    AngleComparison(angleKey, userAngle, proAngle)
}

/** A match percentage from the mean absolute difference across the angles. */
private fun matchPercent(rows: List<AngleComparison>): Double {
    if (rows.isEmpty()) return 0.0
    val averageDifference = rows.sumOf { it.difference } / rows.size
    return (100 - averageDifference).coerceIn(0.0, 100.0)
}

@Composable
private fun OverallScoreCard(phases: List<List<AngleComparison>>) {
    val rows = phases.flatten()
    val averageDifference = if (rows.isEmpty()) 0.0 else rows.sumOf { it.difference } / rows.size
    val match = (100 - averageDifference).coerceIn(0.0, 100.0)

    SectionCard {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                "Overall form match",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(12.dp))
            Text(
                "${match.toInt()}%",
                style = MaterialTheme.typography.displaySmall,
                fontWeight = FontWeight.Bold,
                color = matchColor(match),
            )
            Spacer(Modifier.height(4.dp))
            Text(
                "Average difference: ${Formatting.degrees(averageDifference)} across " +
                    "${rows.size} angles",
                style = MaterialTheme.typography.bodySmall,
                color = AppColors.Muted,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun PhaseCard(
    phase: String,
    rows: List<AngleComparison>,
    expanded: Boolean,
    onToggle: () -> Unit,
) {
    val match = matchPercent(rows)

    SectionCard {
        Column(Modifier.fillMaxWidth()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClick = onToggle),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        Formatting.phaseLabel(phase),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                    )
                    Text(
                        "Phase match: ${match.toInt()}%",
                        style = MaterialTheme.typography.bodySmall,
                        color = matchColor(match),
                        fontWeight = FontWeight.SemiBold,
                    )
                }
                Icon(
                    if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                    contentDescription = if (expanded) "Collapse" else "Expand",
                    tint = AppColors.Muted,
                )
            }

            AnimatedVisibility(expanded) {
                Column(Modifier.padding(top = 8.dp)) {
                    Row(Modifier.fillMaxWidth()) {
                        HeaderCell("Angle", 2.5f)
                        HeaderCell("You", 1.2f, TextAlign.Center)
                        HeaderCell("Pro", 1.2f, TextAlign.Center)
                        HeaderCell("Diff", 1.2f, TextAlign.Center)
                    }
                    HorizontalDivider(Modifier.padding(vertical = 4.dp))
                    rows.forEach { row ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 4.dp),
                        ) {
                            BodyCell(Formatting.angleLabel(row.angleKey), 2.5f)
                            BodyCell("${row.userAngle.toInt()}°", 1.2f, TextAlign.Center)
                            BodyCell("${row.proAngle.toInt()}°", 1.2f, TextAlign.Center)
                            BodyCell(
                                text = "${row.difference.toInt()}°",
                                weight = 1.2f,
                                align = TextAlign.Center,
                                color = differenceColor(row.difference),
                                bold = true,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.HeaderCell(
    text: String,
    weight: Float,
    align: TextAlign = TextAlign.Start,
) {
    Text(
        text,
        modifier = Modifier.weight(weight),
        style = MaterialTheme.typography.labelMedium,
        fontWeight = FontWeight.Bold,
        textAlign = align,
    )
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.BodyCell(
    text: String,
    weight: Float,
    align: TextAlign = TextAlign.Start,
    color: Color = AppColors.OnSurface,
    bold: Boolean = false,
) {
    Text(
        text,
        modifier = Modifier.weight(weight),
        style = MaterialTheme.typography.bodySmall,
        textAlign = align,
        color = color,
        fontWeight = if (bold) FontWeight.SemiBold else FontWeight.Normal,
    )
}

private fun differenceColor(difference: Double): Color = when {
    difference < 10 -> AppColors.Good
    difference < 25 -> AppColors.Warning
    else -> AppColors.Bad
}

private fun matchColor(match: Double): Color = when {
    match >= 90 -> AppColors.Good
    match >= 75 -> AppColors.Warning
    else -> AppColors.Bad
}
