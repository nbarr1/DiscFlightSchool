package com.discflightschool.app.ui.screens.formcoach

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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.components.SectionCard
import com.discflightschool.app.ui.components.rememberVideoPickers
import com.discflightschool.app.ui.theme.AppColors
import com.discflightschool.core.model.ThrowTypes
import kotlinx.coroutines.launch

/**
 * The entry point for form analysis: pick who to compare against, then bring a
 * video in.
 *
 * Throw type is chosen before the pro, because not every player in the baseline
 * database has forehand data — picking the type first keeps the list honest
 * rather than offering a comparison that has nothing behind it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FormCoachScreen(
    onBack: () -> Unit,
    onOpenHistory: () -> Unit,
    onVideoSelected: () -> Unit,
    onOpenAnalysis: () -> Unit,
) {
    val container = LocalAppContainer.current
    val workbench = container.workbench
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }

    var players by remember { mutableStateOf<List<String>>(emptyList()) }
    var playersWithForehand by remember { mutableStateOf<Set<String>>(emptySet()) }
    var playersLoaded by remember { mutableStateOf(false) }
    var proMenuExpanded by remember { mutableStateOf(false) }

    var throwType by remember { mutableStateOf(workbench.throwType) }
    var selectedPro by remember { mutableStateOf(workbench.proPlayer) }
    var isLeftHanded by remember { mutableStateOf(workbench.isLeftHanded) }

    LaunchedEffect(Unit) {
        val database = container.proBaselineRepository.database()
        if (database != null) {
            players = database.playerNames
            playersWithForehand = players
                .filter { database.hasThrowType(it, ThrowTypes.FOREHAND) }
                .toSet()
        }
        playersLoaded = true
    }

    val filteredPlayers = if (throwType == ThrowTypes.BACKHAND) {
        players
    } else {
        players.filter { it in playersWithForehand }
    }

    fun startSession(videoPath: String) {
        workbench.startFormSession(
            videoPath = videoPath,
            proPlayer = selectedPro,
            throwType = throwType,
            isLeftHanded = isLeftHanded,
        )
        onVideoSelected()
    }

    val pickers = rememberVideoPickers(
        onVideoReady = { path -> startSession(path) },
        onFailed = { message -> scope.launch { snackbarHostState.showSnackbar(message) } },
    )

    Scaffold(
        topBar = {
            AppTopBar(title = "Form Coach", onBack = onBack) {
                IconButton(onClick = onOpenHistory) {
                    Icon(Icons.Default.History, contentDescription = "Session history")
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
        ) {
            SectionCard(title = "Compare with a pro", accent = AppColors.FormCoach) {
                Column {
                    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                        SegmentedButton(
                            selected = throwType == ThrowTypes.BACKHAND,
                            onClick = {
                                throwType = ThrowTypes.BACKHAND
                            },
                            shape = SegmentedButtonDefaults.itemShape(index = 0, count = 2),
                        ) {
                            Text("Backhand")
                        }
                        SegmentedButton(
                            selected = throwType == ThrowTypes.FOREHAND,
                            onClick = {
                                throwType = ThrowTypes.FOREHAND
                                // Not every pro has forehand data; a stale
                                // selection would compare against nothing.
                                if (selectedPro != null && selectedPro !in playersWithForehand) {
                                    selectedPro = null
                                }
                            },
                            shape = SegmentedButtonDefaults.itemShape(index = 1, count = 2),
                        ) {
                            Text("Forehand")
                        }
                    }

                    Spacer(Modifier.height(12.dp))

                    if (!playersLoaded) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = androidx.compose.foundation.layout.Arrangement.Center,
                        ) {
                            CircularProgressIndicator(
                                strokeWidth = 2.dp,
                                modifier = Modifier.size(24.dp),
                            )
                        }
                    } else {
                        ExposedDropdownMenuBox(
                            expanded = proMenuExpanded,
                            onExpandedChange = { proMenuExpanded = it },
                        ) {
                            OutlinedTextField(
                                value = selectedPro ?: "— None —",
                                onValueChange = {},
                                readOnly = true,
                                label = { Text("Pro player (optional)") },
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
                                    text = { Text("— None —") },
                                    onClick = {
                                        selectedPro = null
                                        proMenuExpanded = false
                                    },
                                )
                                filteredPlayers.forEach { player ->
                                    DropdownMenuItem(
                                        text = { Text(player) },
                                        onClick = {
                                            selectedPro = player
                                            proMenuExpanded = false
                                        },
                                    )
                                }
                            }
                        }
                    }

                    Spacer(Modifier.height(12.dp))

                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("Left-handed thrower", fontWeight = FontWeight.Medium)
                            Text(
                                "Mirrors the angle analysis, so the throwing arm is always " +
                                    "scored as the dominant one.",
                                style = MaterialTheme.typography.labelSmall,
                                color = AppColors.Muted,
                            )
                        }
                        Switch(checked = isLeftHanded, onCheckedChange = { isLeftHanded = it })
                    }
                }
            }

            Spacer(Modifier.height(20.dp))

            Button(
                onClick = { pickers.pickFromLibrary() },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Default.VideoLibrary, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Upload form video")
            }

            Spacer(Modifier.height(12.dp))

            Button(
                onClick = { pickers.recordVideo() },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Default.Videocam, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Record form video")
            }

            val lastAnalysis = workbench.analysis
            if (lastAnalysis != null) {
                Spacer(Modifier.height(20.dp))
                SectionCard(title = "Last analysis", accent = AppColors.FormCoach) {
                    Column {
                        if (lastAnalysis.isMock) {
                            Text(
                                lastAnalysis.failureReason
                                    ?: "Pose detection failed on the last video.",
                                color = AppColors.Warning,
                                style = MaterialTheme.typography.bodySmall,
                            )
                        } else {
                            Text("Frames: ${lastAnalysis.frames.size}")
                        }
                        Spacer(Modifier.height(12.dp))
                        Button(onClick = onOpenAnalysis) { Text("View analysis") }
                    }
                }
            }

            Spacer(Modifier.height(24.dp))
        }
    }
}
