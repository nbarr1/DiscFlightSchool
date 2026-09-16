package com.discflightschool.app.ui.screens.roulette

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.EmojiEvents
import androidx.compose.material.icons.filled.Home
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.ui.Formatting
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.components.LoadingState
import com.discflightschool.app.ui.components.SectionCard
import com.discflightschool.app.ui.theme.AppColors
import com.discflightschool.core.model.HoleScore
import com.discflightschool.core.model.ScoredRound

/**
 * The scorecard for the round in progress, or a saved one by id.
 *
 * Each hole tile opens the throws behind it: a 4 taken with three 2.5x
 * challenges is a different hole from a 4 taken flat-footed, and the weighted
 * total only makes sense if you can see which one it was.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScorecardScreen(
    onBack: () -> Unit,
    onFinish: () -> Unit,
    savedRoundId: String? = null,
) {
    val container = LocalAppContainer.current
    val scoring = container.scoringRepository
    val currentRound by scoring.currentRound.collectAsStateWithLifecycle()
    val savedRounds by scoring.savedRounds.collectAsStateWithLifecycle()

    val round = if (savedRoundId != null) {
        savedRounds.firstOrNull { it.id == savedRoundId }
    } else {
        currentRound
    }

    var detailScore by remember { mutableStateOf<HoleScore?>(null) }

    if (round == null) {
        Scaffold(topBar = { AppTopBar(title = "Scorecard", onBack = onBack) }) { padding ->
            LoadingState("No round to show", Modifier.padding(padding))
        }
        return
    }

    Scaffold(
        topBar = {
            AppTopBar(title = "Scorecard", onBack = onBack) {
                if (round.isComplete && savedRoundId == null) {
                    IconButton(
                        onClick = {
                            scoring.clearCurrentRound()
                            onFinish()
                        },
                    ) {
                        Icon(Icons.Default.Home, contentDescription = "Finish and go home")
                    }
                }
            }
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                if (round.isComplete) "Final scorecard" else "Current scorecard",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(8.dp))
            Text(
                "Started: ${Formatting.dateTime(round.startedAt)}",
                color = AppColors.Muted,
                style = MaterialTheme.typography.bodySmall,
            )
            round.completedAt?.let {
                Text(
                    "Completed: ${Formatting.dateTime(it)}",
                    color = AppColors.Muted,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            Spacer(Modifier.height(24.dp))

            round.playerNames.forEach { player ->
                PlayerScorecard(
                    round = round,
                    playerName = player,
                    onHoleClick = { detailScore = it },
                )
                Spacer(Modifier.height(16.dp))
            }

            if (round.isComplete) {
                Spacer(Modifier.height(8.dp))
                Leaderboard(round)
            }

            Spacer(Modifier.height(24.dp))
        }
    }

    detailScore?.let { score ->
        ModalBottomSheet(onDismissRequest = { detailScore = null }) {
            Column(Modifier.padding(20.dp)) {
                Text(
                    "Hole ${score.holeNumber} — ${score.strokes} strokes (par ${score.par})",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                )
                HorizontalDivider(Modifier.padding(vertical = 12.dp))
                score.throws.forEach { record ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(
                            modifier = Modifier
                                .size(28.dp)
                                .background(
                                    if (record.isPutt) {
                                        AppColors.KnowledgeBase.copy(alpha = 0.24f)
                                    } else {
                                        AppColors.Roulette.copy(alpha = 0.24f)
                                    },
                                    CircleShape,
                                ),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                "${record.throwNumber}",
                                style = MaterialTheme.typography.labelSmall,
                                fontWeight = FontWeight.Bold,
                            )
                        }
                        Spacer(Modifier.width(10.dp))
                        Text(
                            text = if (record.isPutt) {
                                record.challenge.puttStyleDescription
                            } else {
                                with(record.challenge) {
                                    "${shotTypeDescription.substringBefore(" - ")} · " +
                                        "${discName ?: "Any"} · ${powerModifier.displayName} · " +
                                        hindrance.displayName
                                }
                            },
                            modifier = Modifier.weight(1f),
                            style = MaterialTheme.typography.bodySmall,
                        )
                        Text(
                            "${Formatting.decimal(record.multiplier)}x",
                            fontWeight = FontWeight.Bold,
                            color = Formatting.difficultyColor(record.multiplier),
                        )
                    }
                }
                Spacer(Modifier.height(12.dp))
                Text(
                    "Average multiplier: ${Formatting.decimal(score.averageMultiplier, 2)}x",
                    color = AppColors.Muted,
                    style = MaterialTheme.typography.bodySmall,
                )
                Spacer(Modifier.height(24.dp))
            }
        }
    }
}

@Composable
private fun PlayerScorecard(
    round: ScoredRound,
    playerName: String,
    onHoleClick: (HoleScore) -> Unit,
) {
    val playerScores = round.scores.filter { it.playerName == playerName }
    val scoreToPar = round.rawScoreToPar(playerName)

    SectionCard {
        Column(Modifier.fillMaxWidth()) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    playerName,
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                    color = AppColors.Roulette,
                )
                Box(
                    modifier = Modifier
                        .background(scoreColor(scoreToPar), RoundedCornerShape(12.dp))
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                ) {
                    Text(
                        Formatting.scoreToPar(scoreToPar),
                        fontWeight = FontWeight.Bold,
                        color = AppColors.Background,
                        style = MaterialTheme.typography.titleMedium,
                    )
                }
            }

            HorizontalDivider(Modifier.padding(vertical = 12.dp))

            if (playerScores.isNotEmpty()) {
                Text(
                    "Hole by hole",
                    style = MaterialTheme.typography.labelLarge,
                    color = AppColors.Muted,
                    fontWeight = FontWeight.Bold,
                )
                Spacer(Modifier.height(12.dp))
                LazyVerticalGrid(
                    columns = GridCells.Fixed(9),
                    modifier = Modifier.heightIn(max = 220.dp),
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    items(playerScores.size) { index ->
                        val score = playerScores[index]
                        HoleTile(score) { onHoleClick(score) }
                    }
                }
                Spacer(Modifier.height(16.dp))
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceAround,
            ) {
                StatColumn("Strokes", "${round.totalRawStrokes(playerName)}")
                StatColumn("Par", "${round.totalPar}")
                StatColumn("Score", Formatting.scoreToPar(scoreToPar))
                if (round.useWeighting) {
                    StatColumn(
                        "Weighted",
                        Formatting.decimal(round.totalWeightedScore(playerName)),
                    )
                }
            }
        }
    }
}

@Composable
private fun HoleTile(score: HoleScore, onClick: () -> Unit) {
    val color = scoreColor(score.strokes - score.par)
    Column(
        modifier = Modifier
            .background(color.copy(alpha = 0.2f), RoundedCornerShape(4.dp))
            .border(1.dp, color, RoundedCornerShape(4.dp))
            .clickable(onClick = onClick)
            .padding(vertical = 4.dp)
            .fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            "${score.holeNumber}",
            style = MaterialTheme.typography.labelSmall,
            color = AppColors.Muted,
        )
        Text(
            "${score.strokes}",
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.Bold,
            color = color,
        )
        Text(
            "${Formatting.decimal(score.averageMultiplier)}x",
            style = MaterialTheme.typography.labelSmall,
            color = AppColors.Muted,
        )
    }
}

@Composable
private fun StatColumn(label: String, value: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(label, style = MaterialTheme.typography.labelMedium, color = AppColors.Muted)
        Spacer(Modifier.height(4.dp))
        Text(value, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun Leaderboard(round: ScoredRound) {
    val standings = round.playerNames
        .map { player ->
            Triple(
                player,
                round.rawScoreToPar(player),
                round.totalWeightedScore(player),
            )
        }
        .sortedBy { if (round.useWeighting) it.third else it.second.toDouble() }

    SectionCard(accent = AppColors.Warning) {
        Column(Modifier.fillMaxWidth()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Default.EmojiEvents,
                    contentDescription = null,
                    tint = AppColors.Warning,
                    modifier = Modifier.size(32.dp),
                )
                Spacer(Modifier.width(12.dp))
                Text(
                    "Final standings",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                )
            }
            HorizontalDivider(Modifier.padding(vertical = 12.dp))

            standings.forEachIndexed { index, (player, raw, weighted) ->
                val isWinner = index == 0
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(bottom = 8.dp)
                        .background(
                            if (isWinner) {
                                AppColors.Warning.copy(alpha = 0.16f)
                            } else {
                                Color.White.copy(alpha = 0.04f)
                            },
                            RoundedCornerShape(8.dp),
                        )
                        .border(
                            width = if (isWinner) 2.dp else 1.dp,
                            color = if (isWinner) AppColors.Warning else AppColors.Muted,
                            shape = RoundedCornerShape(8.dp),
                        )
                        .padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        modifier = Modifier
                            .size(32.dp)
                            .background(
                                if (isWinner) AppColors.Warning else AppColors.Muted,
                                CircleShape,
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            "${index + 1}",
                            fontWeight = FontWeight.Bold,
                            color = AppColors.Background,
                        )
                    }
                    Spacer(Modifier.width(12.dp))
                    Text(
                        player,
                        modifier = Modifier.weight(1f),
                        fontWeight = if (isWinner) FontWeight.Bold else FontWeight.Normal,
                    )
                    Column(horizontalAlignment = Alignment.End) {
                        Text(
                            Formatting.scoreToPar(raw),
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                        )
                        if (round.useWeighting) {
                            Text(
                                "Weighted: ${Formatting.decimal(weighted)}",
                                style = MaterialTheme.typography.labelSmall,
                                color = AppColors.Muted,
                            )
                        }
                    }
                }
            }
        }
    }
}
