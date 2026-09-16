package com.discflightschool.app.ui.screens.roulette

import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Casino
import androidx.compose.material.icons.filled.DeleteSweep
import androidx.compose.material3.AlertDialog
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.ui.Formatting
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.components.EmptyState
import com.discflightschool.app.ui.theme.AppColors
import com.discflightschool.core.model.RouletteResult

/** Every spin the app has recorded, newest first. */
@Composable
fun RouletteHistoryScreen(onBack: () -> Unit) {
    val container = LocalAppContainer.current
    val history by container.rouletteHistoryRepository.history.collectAsStateWithLifecycle()
    var confirmClear by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            AppTopBar(title = "Spin history", onBack = onBack) {
                if (history.isNotEmpty()) {
                    IconButton(onClick = { confirmClear = true }) {
                        Icon(Icons.Default.DeleteSweep, contentDescription = "Clear history")
                    }
                }
            }
        },
    ) { padding ->
        if (history.isEmpty()) {
            EmptyState(
                icon = Icons.Default.Casino,
                title = "No spins yet",
                message = "Head to Disc Roulette and spin to start your log.",
                modifier = Modifier.padding(padding),
            )
            return@Scaffold
        }

        Column(Modifier.padding(padding).fillMaxSize()) {
            SummaryBar(
                total = history.size,
                averageDifficulty = history.sumOf { it.difficultyMultiplier } / history.size,
            )
            LazyColumn(
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    horizontal = 12.dp,
                    vertical = 8.dp,
                ),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(history) { result -> SpinCard(result) }
            }
        }
    }

    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("Clear spin history") },
            text = { Text("This permanently deletes every saved spin.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        container.rouletteHistoryRepository.clearHistory()
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
private fun SummaryBar(total: Int, averageDifficulty: Double) {
    Surface(
        color = AppColors.Roulette.copy(alpha = 0.12f),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
        ) {
            StatChip("$total", "Total spins", Icons.Default.Casino)
            StatChip(Formatting.decimal(averageDifficulty, 2), "Avg difficulty", Icons.Default.BarChart)
        }
    }
}

@Composable
private fun StatChip(
    value: String,
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null, tint = AppColors.Roulette, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(4.dp))
            Text(value, fontWeight = FontWeight.Bold)
        }
        Text(label, style = MaterialTheme.typography.labelSmall, color = AppColors.Muted)
    }
}

@Composable
private fun SpinCard(result: RouletteResult) {
    val difficulty = result.difficultyMultiplier
    val color = Formatting.difficultyColor(difficulty)

    Surface(
        shape = RoundedCornerShape(12.dp),
        color = AppColors.Surface,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .background(color.copy(alpha = 0.16f), CircleShape)
                    .border(1.5.dp, color, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    Formatting.decimal(difficulty),
                    fontWeight = FontWeight.Bold,
                    style = MaterialTheme.typography.labelLarge,
                    color = color,
                )
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    text = if (result.isPutt) {
                        result.puttStyleDescription
                    } else {
                        "${result.shotTypeDescription} · ${result.discName ?: "Any"}"
                    },
                    fontWeight = FontWeight.Bold,
                    style = MaterialTheme.typography.bodyMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (!result.isPutt) {
                    Text(
                        "${result.powerModifier.displayName} · ${result.hindrance.displayName}",
                        style = MaterialTheme.typography.labelSmall,
                        color = AppColors.Muted,
                    )
                }
            }
            Spacer(Modifier.width(8.dp))
            Text(
                Formatting.relativeDate(result.timestamp),
                style = MaterialTheme.typography.labelSmall,
                color = AppColors.Muted,
            )
        }
    }
}
