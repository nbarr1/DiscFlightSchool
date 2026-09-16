package com.discflightschool.app.ui.screens.formcoach

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DeleteSweep
import androidx.compose.material.icons.filled.History
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.ui.Formatting
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.components.EmptyState
import com.discflightschool.app.ui.theme.AppColors
import com.discflightschool.core.data.FormHistoryRepository
import com.discflightschool.core.model.FormSessionRecord
import com.discflightschool.core.model.ThrowTypes

/** Every saved form session, with a score trend per throw type. */
@Composable
fun FormHistoryScreen(onBack: () -> Unit) {
    val container = LocalAppContainer.current
    val repository = container.formHistoryRepository
    val sessions by repository.sessions.collectAsStateWithLifecycle()
    var confirmClear by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            AppTopBar(title = "Form history", onBack = onBack) {
                if (sessions.isNotEmpty()) {
                    IconButton(onClick = { confirmClear = true }) {
                        Icon(Icons.Default.DeleteSweep, contentDescription = "Clear history")
                    }
                }
            }
        },
    ) { padding ->
        if (sessions.isEmpty()) {
            EmptyState(
                icon = Icons.Default.History,
                title = "No sessions recorded yet",
                message = "Analyze a form video to start tracking progress.",
                modifier = Modifier.padding(padding),
            )
            return@Scaffold
        }

        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize(),
        ) {
            TrendSection(repository, ThrowTypes.BACKHAND, "Backhand")
            TrendSection(repository, ThrowTypes.FOREHAND, "Forehand")
            HorizontalDivider()

            LazyColumn(
                contentPadding = PaddingValues(12.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(sessions, key = { it.id }) { session -> SessionCard(session) }
            }
        }
    }

    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("Clear history") },
            text = { Text("Delete all saved form sessions? This cannot be undone.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        repository.clearHistory()
                        confirmClear = false
                    },
                ) {
                    Text("Clear", color = AppColors.Bad)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmClear = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun TrendSection(
    repository: FormHistoryRepository,
    throwType: String,
    label: String,
) {
    val trend = repository.trend(throwType, n = 10)
    if (trend.isEmpty()) return

    Column(Modifier.padding(start = 16.dp, top = 12.dp, end = 16.dp)) {
        Text(
            "$label trend",
            fontWeight = FontWeight.Bold,
            color = AppColors.Muted,
            style = MaterialTheme.typography.labelLarge,
        )
        Spacer(Modifier.height(6.dp))
        TrendChart(
            scores = trend.map { it.score },
            modifier = Modifier
                .fillMaxWidth()
                .height(60.dp),
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(
                "${trend.size} sessions",
                style = MaterialTheme.typography.labelSmall,
                color = AppColors.Muted,
            )
            Text(
                "Latest: ${Formatting.decimal(trend.last().score)}",
                style = MaterialTheme.typography.labelSmall,
                color = Formatting.scoreColor(trend.last().score),
                fontWeight = FontWeight.Bold,
            )
        }
        Spacer(Modifier.height(8.dp))
    }
}

/** Scores over time, plotted against the full 0-100 range. */
@Composable
private fun TrendChart(scores: List<Double>, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        if (scores.size < 2) return@Canvas
        val stepX = size.width / (scores.size - 1)

        fun yFor(score: Double) = size.height - (score / 100.0).toFloat() * size.height

        val line = Path()
        val fill = Path()
        scores.forEachIndexed { index, score ->
            val x = index * stepX
            val y = yFor(score)
            if (index == 0) {
                line.moveTo(x, y)
                fill.moveTo(x, size.height)
                fill.lineTo(x, y)
            } else {
                line.lineTo(x, y)
                fill.lineTo(x, y)
            }
        }
        fill.lineTo((scores.size - 1) * stepX, size.height)
        fill.close()

        drawPath(fill, AppColors.FlightTracker.copy(alpha = 0.16f))
        drawPath(line, AppColors.FlightTracker, style = Stroke(width = 2.dp.toPx()))

        scores.forEachIndexed { index, score ->
            drawCircle(
                AppColors.FlightTracker,
                radius = 3.dp.toPx(),
                center = Offset(index * stepX, yFor(score)),
            )
        }
    }
}

@Composable
private fun SessionCard(session: FormSessionRecord) {
    val color = Formatting.scoreColor(session.score)

    Surface(
        shape = RoundedCornerShape(12.dp),
        color = AppColors.Surface,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(56.dp)
                    .border(2.5.dp, color, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(
                        "${session.score.toInt()}",
                        fontWeight = FontWeight.Bold,
                        color = color,
                        style = MaterialTheme.typography.titleMedium,
                    )
                    Text(
                        scoreLabelShort(session.score),
                        style = MaterialTheme.typography.labelSmall,
                        color = color,
                    )
                }
            }
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    Formatting.dateTime(session.date),
                    fontWeight = FontWeight.Bold,
                    style = MaterialTheme.typography.bodyMedium,
                )
                Spacer(Modifier.height(4.dp))
                Row {
                    Chip(
                        if (session.throwType == ThrowTypes.BACKHAND) "Backhand" else "Forehand",
                        AppColors.Roulette,
                    )
                    session.proPlayer?.let {
                        Spacer(Modifier.width(6.dp))
                        Chip("vs $it", AppColors.KnowledgeBase)
                    }
                }
                Spacer(Modifier.height(4.dp))
                Text(
                    "${session.frameCount} frames analyzed",
                    style = MaterialTheme.typography.labelSmall,
                    color = AppColors.Muted,
                )
            }
        }
    }
}

@Composable
private fun Chip(label: String, color: Color) {
    Box(
        modifier = Modifier
            .background(color.copy(alpha = 0.16f), RoundedCornerShape(10.dp))
            .border(1.dp, color.copy(alpha = 0.48f), RoundedCornerShape(10.dp))
            .padding(horizontal = 8.dp, vertical = 2.dp),
    ) {
        Text(label, style = MaterialTheme.typography.labelSmall, color = color)
    }
}

private fun scoreLabelShort(score: Double): String = when {
    score >= 90 -> "Excellent"
    score >= 80 -> "Good"
    score >= 70 -> "Fair"
    score >= 60 -> "Work"
    else -> "Poor"
}
