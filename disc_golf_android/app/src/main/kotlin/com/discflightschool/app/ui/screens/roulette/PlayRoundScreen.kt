package com.discflightschool.app.ui.screens.roulette

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
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
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.ArrowForward
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.FlashOn
import androidx.compose.material.icons.filled.GpsFixed
import androidx.compose.material.icons.filled.ReceiptLong
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.SportsGolf
import androidx.compose.material.icons.filled.Undo
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.ui.Formatting
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.components.LabeledRow
import com.discflightschool.app.ui.components.LoadingState
import com.discflightschool.app.ui.components.SectionCard
import com.discflightschool.app.ui.theme.AppColors
import com.discflightschool.core.model.DiscLists
import com.discflightschool.core.model.Hindrance
import com.discflightschool.core.model.HoleScore
import com.discflightschool.core.model.RouletteResult
import com.discflightschool.core.model.ThrowRecord
import kotlinx.coroutines.launch

/**
 * Plays a scored round hole by hole.
 *
 * Each throw is spun before it is taken, so a hole's score carries not just the
 * stroke count but how hard every stroke was — which is what makes the weighted
 * total mean anything.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlayRoundScreen(
    onBack: () -> Unit,
    onOpenScorecard: () -> Unit,
    onRoundComplete: () -> Unit,
) {
    val container = LocalAppContainer.current
    val scoring = container.scoringRepository
    val round by scoring.currentRound.collectAsStateWithLifecycle()
    val currentPlayer by scoring.currentPlayer.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }

    val activeRound = round
    if (activeRound == null || currentPlayer == null) {
        Scaffold(topBar = { AppTopBar(title = "Round", onBack = onBack) }) { padding ->
            LoadingState("No active round", Modifier.padding(padding))
        }
        return
    }

    var holeNumber by remember { mutableStateOf(1) }
    var isSpinning by remember { mutableStateOf(false) }
    var isPutting by remember { mutableStateOf(false) }
    var challenge by remember { mutableStateOf<RouletteResult?>(null) }
    var showUndoDialog by remember { mutableStateOf(false) }
    val rotation = remember { Animatable(0f) }

    val currentThrows = remember { mutableStateListOf<ThrowRecord>() }
    val playerThrows = remember { mutableStateMapOf<String, List<ThrowRecord>>() }
    val playerStrokes = remember { mutableStateMapOf<String, Int>() }
    val completedPlayers = remember { mutableStateListOf<String>() }
    var playerMenuExpanded by remember { mutableStateOf(false) }

    val holePar = activeRound.coursePars.getOrElse(holeNumber - 1) { 3 }
    val remainingPlayers = activeRound.playerNames.filterNot { it in completedPlayers }

    // Every player has finished the last hole: the round is over.
    LaunchedEffect(holeNumber, completedPlayers.size) {
        if (holeNumber > activeRound.coursePars.size &&
            completedPlayers.size == activeRound.playerNames.size
        ) {
            onRoundComplete()
        }
    }

    fun spin() {
        if (isSpinning) return
        isSpinning = true
        challenge = null
        scope.launch {
            rotation.snapTo(0f)
            rotation.animateTo(
                targetValue = 3f * 360f,
                animationSpec = tween(durationMillis = 2000, easing = LinearOutSlowInEasing),
            )
            val discs = if (isPutting) DiscLists.putting else DiscLists.scoringRound
            challenge = if (isPutting) {
                RouletteResult.generatePutt(discs)
            } else {
                RouletteResult.generate(discs)
            }
            isSpinning = false
        }
    }

    fun recordThrow() {
        val spun = challenge ?: return
        currentThrows += ThrowRecord(
            throwNumber = currentThrows.size + 1,
            challenge = spun,
            isPutt = isPutting,
        )
        challenge = null
        // Putting is per-throw, so the toggle resets for the next one.
        isPutting = false
    }

    fun holedOut() {
        val player = currentPlayer ?: return
        challenge?.let { spun ->
            currentThrows += ThrowRecord(
                throwNumber = currentThrows.size + 1,
                challenge = spun,
                isPutt = isPutting,
            )
        }

        val strokes = currentThrows.size
        scoring.addHoleScore(
            HoleScore(
                holeNumber = holeNumber,
                par = activeRound.coursePars.getOrElse(holeNumber - 1) { 3 },
                strokes = strokes,
                throws = currentThrows.toList(),
                playerName = player,
            ),
        )

        completedPlayers += player
        playerStrokes[player] = strokes
        playerThrows[player] = currentThrows.toList()
        currentThrows.clear()
        challenge = null
        isPutting = false

        activeRound.playerNames.firstOrNull { it !in completedPlayers }?.let { next ->
            scoring.setCurrentPlayer(next)
            currentThrows.addAll(playerThrows[next].orEmpty())
        }
    }

    fun advance() {
        if (holeNumber >= activeRound.coursePars.size) {
            onRoundComplete()
            return
        }
        holeNumber++
        completedPlayers.clear()
        playerThrows.clear()
        playerStrokes.clear()
        currentThrows.clear()
        challenge = null
        isPutting = false
        activeRound.playerNames.firstOrNull()?.let { scoring.setCurrentPlayer(it) }
    }

    fun undoLastScore() {
        scoring.undoLastScore()
        val updated = scoring.currentRound.value ?: return

        // Rewind to the first hole that is not finished for everyone.
        holeNumber = (1..updated.coursePars.size).firstOrNull { hole ->
            updated.playerNames.count { player ->
                updated.scores.any { it.holeNumber == hole && it.playerName == player }
            } < updated.playerNames.size
        } ?: 1

        completedPlayers.clear()
        playerThrows.clear()
        playerStrokes.clear()
        for (player in updated.playerNames) {
            val score = updated.scores.firstOrNull {
                it.holeNumber == holeNumber && it.playerName == player
            } ?: continue
            completedPlayers += player
            playerStrokes[player] = score.strokes
            playerThrows[player] = score.throws
        }

        currentThrows.clear()
        challenge = null
        isPutting = false
        scope.launch { snackbarHostState.showSnackbar("Score removed") }
    }

    Scaffold(
        topBar = {
            AppTopBar(title = "Hole $holeNumber", onBack = onBack) {
                IconButton(onClick = onOpenScorecard) {
                    Icon(Icons.Default.ReceiptLong, contentDescription = "Scorecard")
                }
                if (activeRound.scores.isNotEmpty()) {
                    IconButton(onClick = { showUndoDialog = true }) {
                        Icon(Icons.Default.Undo, contentDescription = "Undo last score")
                    }
                }
            }
        },
        snackbarHost = { SnackbarHost(snackbarHostState) },
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            SectionCard {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceAround,
                ) {
                    StatItem("Hole", "$holeNumber/${activeRound.coursePars.size}")
                    StatItem("Par", "$holePar")
                    StatItem(
                        "Completed",
                        "${completedPlayers.size}/${activeRound.playerNames.size}",
                    )
                }
            }

            if (completedPlayers.isNotEmpty()) {
                Spacer(Modifier.height(16.dp))
                SectionCard(title = "Completed this hole", accent = AppColors.Good) {
                    Column(Modifier.fillMaxWidth()) {
                        completedPlayers.forEach { player ->
                            val strokes = playerStrokes[player] ?: 0
                            val throws = playerThrows[player].orEmpty()
                            val average = if (throws.isEmpty()) {
                                1.0
                            } else {
                                throws.sumOf { it.multiplier } / throws.size
                            }
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(vertical = 4.dp),
                                horizontalArrangement = Arrangement.SpaceBetween,
                            ) {
                                Text(player, color = AppColors.Muted)
                                Text(
                                    "$strokes (${Formatting.scoreToPar(strokes - holePar)}) " +
                                        "${Formatting.decimal(average)}x",
                                    fontWeight = FontWeight.Bold,
                                    color = scoreColor(strokes - holePar),
                                )
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(16.dp))

            if (remainingPlayers.isEmpty()) {
                SectionCard {
                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Icon(
                            Icons.Default.CheckCircle,
                            contentDescription = null,
                            tint = AppColors.Good,
                            modifier = Modifier.size(64.dp),
                        )
                        Spacer(Modifier.height(16.dp))
                        Text(
                            "Hole complete",
                            style = MaterialTheme.typography.headlineSmall,
                            fontWeight = FontWeight.Bold,
                        )
                        Spacer(Modifier.height(24.dp))
                        Button(onClick = { advance() }) {
                            Icon(Icons.Default.ArrowForward, contentDescription = null)
                            Spacer(Modifier.width(8.dp))
                            Text(
                                if (holeNumber < activeRound.coursePars.size) {
                                    "Next hole"
                                } else {
                                    "Finish round"
                                },
                            )
                        }
                    }
                }
            } else {
                val selectedPlayer = currentPlayer.takeIf { it in remainingPlayers }
                    ?: remainingPlayers.first()

                SectionCard(title = "Current player", accent = AppColors.Warning) {
                    ExposedDropdownMenuBox(
                        expanded = playerMenuExpanded,
                        onExpandedChange = { playerMenuExpanded = it },
                    ) {
                        OutlinedTextField(
                            value = selectedPlayer,
                            onValueChange = {},
                            readOnly = true,
                            trailingIcon = {
                                ExposedDropdownMenuDefaults.TrailingIcon(playerMenuExpanded)
                            },
                            modifier = Modifier
                                .fillMaxWidth()
                                .menuAnchor(),
                        )
                        ExposedDropdownMenu(
                            expanded = playerMenuExpanded,
                            onDismissRequest = { playerMenuExpanded = false },
                        ) {
                            remainingPlayers.forEach { player ->
                                DropdownMenuItem(
                                    text = { Text(player) },
                                    onClick = {
                                        // Park the current player's throws before
                                        // switching, so nothing is lost.
                                        currentPlayer?.let {
                                            playerThrows[it] = currentThrows.toList()
                                        }
                                        scoring.setCurrentPlayer(player)
                                        currentThrows.clear()
                                        currentThrows.addAll(playerThrows[player].orEmpty())
                                        challenge = null
                                        isPutting = false
                                        playerMenuExpanded = false
                                    },
                                )
                            }
                        }
                    }
                }

                if (currentThrows.isNotEmpty()) {
                    Spacer(Modifier.height(16.dp))
                    SectionCard {
                        Column(Modifier.fillMaxWidth()) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    "Throws: ${currentThrows.size}",
                                    fontWeight = FontWeight.Bold,
                                )
                                TextButton(onClick = { currentThrows.removeLastOrNull() }) {
                                    Icon(
                                        Icons.Default.Undo,
                                        contentDescription = null,
                                        modifier = Modifier.size(16.dp),
                                    )
                                    Spacer(Modifier.width(4.dp))
                                    Text("Undo")
                                }
                            }
                            HorizontalDivider(Modifier.padding(vertical = 8.dp))
                            currentThrows.forEach { record -> ThrowRow(record) }
                        }
                    }
                }

                Spacer(Modifier.height(16.dp))

                SectionCard {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            imageVector = if (isPutting) {
                                Icons.Default.GpsFixed
                            } else {
                                Icons.Default.SportsGolf
                            },
                            contentDescription = null,
                            tint = if (isPutting) AppColors.KnowledgeBase else AppColors.Roulette,
                        )
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(
                                if (isPutting) "Putting mode" else "Throwing mode",
                                fontWeight = FontWeight.Bold,
                            )
                            Text(
                                if (isPutting) {
                                    "Challenges: putt style, putters only"
                                } else {
                                    "Challenges: shot type, disc, power, hindrance"
                                },
                                style = MaterialTheme.typography.bodySmall,
                                color = AppColors.Muted,
                            )
                        }
                        Switch(
                            checked = isPutting,
                            // Switching mid-challenge would change the spin the
                            // player is already committed to.
                            enabled = challenge == null,
                            onCheckedChange = { isPutting = it },
                        )
                    }
                }

                Spacer(Modifier.height(16.dp))

                val spun = challenge
                if (spun == null) {
                    Text(
                        "Tap the wheel to spin for throw #${currentThrows.size + 1}",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        textAlign = TextAlign.Center,
                    )
                    Spacer(Modifier.height(24.dp))
                    Box(
                        modifier = Modifier
                            .size(250.dp)
                            .clickable(enabled = !isSpinning) { spin() },
                        contentAlignment = Alignment.Center,
                    ) {
                        RouletteWheel(modifier = Modifier.rotate(rotation.value))
                    }
                } else {
                    ChallengeCard(spun, currentThrows.size + 1)
                    Spacer(Modifier.height(24.dp))
                    Row(horizontalArrangement = Arrangement.Center) {
                        Button(
                            onClick = { challenge = null },
                            colors = ButtonDefaults.buttonColors(
                                containerColor = AppColors.Warning,
                            ),
                        ) {
                            Icon(Icons.Default.Refresh, contentDescription = null)
                            Spacer(Modifier.width(8.dp))
                            Text("Re-spin")
                        }
                        Spacer(Modifier.width(12.dp))
                        Button(onClick = { recordThrow() }) {
                            Icon(Icons.Default.ArrowForward, contentDescription = null)
                            Spacer(Modifier.width(8.dp))
                            Text("Next throw")
                        }
                    }
                    Spacer(Modifier.height(12.dp))
                    Button(
                        onClick = { holedOut() },
                        modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(containerColor = AppColors.Good),
                    ) {
                        Icon(Icons.Default.Flag, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Text("Holed out")
                    }
                }
            }

            Spacer(Modifier.height(24.dp))
        }
    }

    if (showUndoDialog) {
        val lastScore = activeRound.scores.lastOrNull()
        AlertDialog(
            onDismissRequest = { showUndoDialog = false },
            title = { Text("Undo last score") },
            text = {
                Text(
                    if (lastScore == null) {
                        "There is nothing to undo."
                    } else {
                        "Remove the score for ${lastScore.playerName} on hole " +
                            "${lastScore.holeNumber}?\n\n" +
                            "Strokes: ${lastScore.strokes} (${lastScore.throws.size} throws)\n" +
                            "Par: ${lastScore.par}"
                    },
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        undoLastScore()
                        showUndoDialog = false
                    },
                ) {
                    Text("Undo", color = AppColors.Bad)
                }
            },
            dismissButton = {
                TextButton(onClick = { showUndoDialog = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun StatItem(label: String, value: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(label, style = MaterialTheme.typography.bodySmall, color = AppColors.Muted)
        Spacer(Modifier.height(4.dp))
        Text(value, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun ThrowRow(record: ThrowRecord) {
    val challenge = record.challenge
    val label = if (record.isPutt) {
        challenge.puttStyleDescription
    } else {
        "${challenge.shotTypeDescription.substringBefore(" - ")} · " +
            "${challenge.discName ?: "Any"} · ${challenge.hindrance.displayName}"
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
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
        Spacer(Modifier.width(8.dp))
        Text(
            label,
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.bodySmall,
            color = AppColors.Muted,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            "${Formatting.decimal(record.multiplier)}x",
            fontWeight = FontWeight.Bold,
            color = Formatting.difficultyColor(record.multiplier),
        )
    }
}

@Composable
private fun ChallengeCard(challenge: RouletteResult, throwNumber: Int) {
    val difficulty = challenge.difficultyMultiplier
    SectionCard {
        Column(Modifier.fillMaxWidth()) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "Throw #$throwNumber${if (challenge.isPutt) " (putt)" else ""}",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                )
                Box(
                    modifier = Modifier
                        .background(
                            Formatting.difficultyColor(difficulty),
                            RoundedCornerShape(12.dp),
                        )
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                ) {
                    Text(
                        "${Formatting.decimal(difficulty)}x",
                        fontWeight = FontWeight.Bold,
                        color = AppColors.Background,
                    )
                }
            }
            HorizontalDivider(Modifier.padding(vertical = 12.dp))

            if (challenge.isPutt) {
                LabeledRow(
                    "Putt style",
                    challenge.puttStyleDescription,
                    Icons.Default.GpsFixed,
                    AppColors.KnowledgeBase,
                )
                Spacer(Modifier.height(12.dp))
                LabeledRow("Disc", challenge.discName ?: "Putter", Icons.Default.Album)
            } else {
                LabeledRow("Shot type", challenge.shotTypeDescription, Icons.Default.SportsGolf)
                Spacer(Modifier.height(12.dp))
                LabeledRow("Disc", challenge.discName ?: "Any disc", Icons.Default.Album)
                Spacer(Modifier.height(12.dp))
                LabeledRow("Power", challenge.powerModifier.displayName, Icons.Default.FlashOn)
                Spacer(Modifier.height(12.dp))
                LabeledRow(
                    "Challenge",
                    challenge.hindrance.displayName,
                    if (challenge.hindrance == Hindrance.NONE) {
                        Icons.Default.CheckCircle
                    } else {
                        Icons.Default.Warning
                    },
                    if (challenge.hindrance == Hindrance.NONE) AppColors.Good else AppColors.Warning,
                )
            }
        }
    }
}

/** Birdie through double bogey, in the colours a scorecard uses. */
internal fun scoreColor(scoreToPar: Int) = when {
    scoreToPar <= -2 -> AppColors.Roulette
    scoreToPar == -1 -> AppColors.FlightTracker
    scoreToPar == 0 -> AppColors.Good
    scoreToPar == 1 -> AppColors.Warning
    else -> AppColors.Bad
}
