package com.discflightschool.app.ui.screens.roulette

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.RemoveCircle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.components.SectionCard
import com.discflightschool.app.ui.theme.AppColors
import com.discflightschool.core.model.ScoredRound
import kotlinx.coroutines.launch

/**
 * Sets up a scored round: who is playing, whether difficulty weighting counts,
 * and what par each hole is.
 */
@Composable
fun StartRoundScreen(onBack: () -> Unit, onRoundStarted: () -> Unit) {
    val container = LocalAppContainer.current
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }

    val playerNames = remember { mutableStateListOf("") }
    var useWeighting by remember { mutableStateOf(true) }
    var customPars by remember { mutableStateOf(false) }
    val pars = remember { ScoredRound.defaultCourse().toMutableStateList() }
    var parPickerHole by remember { mutableStateOf<Int?>(null) }

    Scaffold(
        topBar = { AppTopBar(title = "Start new round", onBack = onBack) },
        snackbarHost = { SnackbarHost(snackbarHostState) },
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            SectionCard {
                Column {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            "Players",
                            style = MaterialTheme.typography.titleLarge,
                            fontWeight = FontWeight.Bold,
                        )
                        Button(onClick = { playerNames.add("") }) {
                            Icon(Icons.Default.Add, contentDescription = null)
                            Spacer(Modifier.width(8.dp))
                            Text("Add player")
                        }
                    }
                    Spacer(Modifier.height(16.dp))

                    playerNames.forEachIndexed { index, name ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(bottom = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            OutlinedTextField(
                                value = name,
                                onValueChange = { playerNames[index] = it },
                                label = { Text("Player ${index + 1} name") },
                                leadingIcon = {
                                    Icon(Icons.Default.Person, contentDescription = null)
                                },
                                singleLine = true,
                                keyboardOptions = KeyboardOptions(
                                    capitalization = KeyboardCapitalization.Words,
                                ),
                                modifier = Modifier.weight(1f),
                            )
                            if (playerNames.size > 1) {
                                IconButton(onClick = { playerNames.removeAt(index) }) {
                                    Icon(
                                        Icons.Default.RemoveCircle,
                                        contentDescription = "Remove player ${index + 1}",
                                        tint = AppColors.Bad,
                                    )
                                }
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(16.dp))

            SectionCard(title = "Scoring options") {
                Column {
                    SwitchRow(
                        title = "Use difficulty weighting",
                        subtitle = "Harder challenges earn bonus points",
                        checked = useWeighting,
                        onCheckedChange = { useWeighting = it },
                    )
                    HorizontalDivider(Modifier.padding(vertical = 8.dp))
                    SwitchRow(
                        title = "Custom pars",
                        subtitle = "Set par for each hole",
                        checked = customPars,
                        onCheckedChange = { customPars = it },
                    )
                }
            }

            if (customPars) {
                Spacer(Modifier.height(16.dp))
                SectionCard {
                    Column {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                "Course setup",
                                style = MaterialTheme.typography.titleLarge,
                                fontWeight = FontWeight.Bold,
                            )
                            TextButton(
                                onClick = {
                                    pars.clear()
                                    pars.addAll(ScoredRound.defaultCourse())
                                },
                            ) {
                                Text("Reset to par 3")
                            }
                        }
                        Spacer(Modifier.height(16.dp))
                        LazyVerticalGrid(
                            columns = GridCells.Fixed(6),
                            modifier = Modifier.heightIn(max = 240.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            items(pars.size) { index ->
                                ParTile(
                                    hole = index + 1,
                                    par = pars[index],
                                    onClick = { parPickerHole = index },
                                )
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(24.dp))

            Button(
                onClick = {
                    val names = playerNames.map { it.trim() }.filter { it.isNotEmpty() }
                    if (names.isEmpty()) {
                        scope.launch {
                            snackbarHostState.showSnackbar("Enter at least one player name")
                        }
                        return@Button
                    }
                    container.scoringRepository.startNewRound(
                        playerNames = names,
                        customPars = if (customPars) pars.toList() else null,
                        useWeighting = useWeighting,
                    )
                    onRoundStarted()
                },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Default.PlayArrow, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Start round")
            }

            Spacer(Modifier.height(24.dp))
        }
    }

    parPickerHole?.let { hole ->
        AlertDialog(
            onDismissRequest = { parPickerHole = null },
            title = { Text("Hole ${hole + 1} par") },
            text = {
                Column {
                    listOf(3, 4, 5).forEach { par ->
                        TextButton(
                            onClick = {
                                pars[hole] = par
                                parPickerHole = null
                            },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(
                                "Par $par",
                                fontWeight = if (pars[hole] == par) {
                                    FontWeight.Bold
                                } else {
                                    FontWeight.Normal
                                },
                            )
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { parPickerHole = null }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun SwitchRow(
    title: String,
    subtitle: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, fontWeight = FontWeight.Medium)
            Text(
                subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = AppColors.Muted,
            )
        }
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

@Composable
private fun ParTile(hole: Int, par: Int, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        color = AppColors.Roulette.copy(alpha = 0.16f),
        shape = MaterialTheme.shapes.small,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("$hole", style = MaterialTheme.typography.labelSmall, color = AppColors.Muted)
            Text(
                "$par",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
            )
        }
    }
}
