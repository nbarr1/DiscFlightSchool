package com.discflightschool.app.ui.screens.settings

import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CloudDone
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.CloudQueue
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.FolderZip
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.PrivacyTip
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Save
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import com.discflightschool.app.ui.components.readableWidth
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.components.SectionCard
import com.discflightschool.app.ui.theme.AppColors
import com.discflightschool.core.data.TrainingDataRepository
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * Detector sensitivity, training data collection, the server it uploads to, and
 * the key that server needs.
 *
 * The key lives in encrypted storage and is write-only from here: the screen
 * can say whether it is set and can remove it, but never shows it back.
 */
@Composable
fun TrainingSettingsScreen(onBack: () -> Unit, onOpenPrivacyPolicy: () -> Unit) {
    val container = LocalAppContainer.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }

    val training = container.trainingDataRepository
    val collector = container.trainingDataCollector

    val threshold by container.detectionSettings.confidenceThreshold.collectAsStateWithLifecycle()
    val isOptedIn by training.isOptedIn.collectAsStateWithLifecycle()
    val serverUrl by training.serverUrl.collectAsStateWithLifecycle()
    val samples by training.samples.collectAsStateWithLifecycle()

    var serverOnline by remember { mutableStateOf<Boolean?>(null) }
    var checkingServer by remember { mutableStateOf(false) }
    var serverUrlDraft by remember(serverUrl) { mutableStateOf(serverUrl) }
    var busyMessage by remember { mutableStateOf<String?>(null) }
    var trainingKeyDialog by remember { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }
    var advancedExpanded by remember { mutableStateOf(false) }
    var hasTrainingKey by remember { mutableStateOf(training.hasApiKey) }

    val pendingCount = samples.count { !it.uploaded }
    val uploadedCount = samples.count { it.uploaded }

    suspend fun checkServerHealth() {
        if (serverUrl.isBlank()) {
            serverOnline = null
            return
        }
        checkingServer = true
        serverOnline = withContext(Dispatchers.IO) {
            runCatching {
                val client = OkHttpClient.Builder()
                    .connectTimeout(5, TimeUnit.SECONDS)
                    .readTimeout(5, TimeUnit.SECONDS)
                    .build()
                val uri = training.endpoint("/health") ?: return@runCatching false
                client.newCall(Request.Builder().url(uri.toURL()).build()).execute()
                    .use { it.isSuccessful }
            }.getOrDefault(false)
        }
        checkingServer = false
    }

    LaunchedEffect(serverUrl) { checkServerHealth() }

    Scaffold(
        topBar = { AppTopBar(title = "Training settings", onBack = onBack) },
        snackbarHost = { SnackbarHost(snackbarHostState) },
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .readableWidth()
                .padding(16.dp),
        ) {
            SectionCard(title = "Disc detection sensitivity") {
                Column {
                    Text(
                        "Used when refining a path you marked by hand. Lower detects more, and " +
                            "may include false positives. Higher is more precise, and may miss a " +
                            "fast-moving disc. Auto-detect uses the Roboflow Workflow's own setting.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(8.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Low", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Slider(
                            value = threshold.toFloat(),
                            onValueChange = {
                                container.detectionSettings.setConfidenceThreshold(it.toDouble())
                            },
                            valueRange = 0.01f..0.5f,
                            steps = 48,
                            modifier = Modifier
                                .weight(1f)
                                .semantics { contentDescription = "Detection sensitivity" },
                        )
                        Text("High", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Text(
                        "Current: ${(threshold * 100).toInt()}% confidence required",
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }

            Spacer(Modifier.height(16.dp))

            SectionCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Help improve disc tracking", fontWeight = FontWeight.Bold)
                        Text(
                            "When enabled, the frames you mark by hand during flight tracking " +
                                "are saved so they can train the detection model.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Switch(checked = isOptedIn, onCheckedChange = { training.setOptIn(it) })
                }
            }

            Spacer(Modifier.height(16.dp))

            SectionCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    val (icon, tint, label) = when {
                        checkingServer ->
                            Triple(Icons.Default.Sync, AppColors.Muted, "Checking server...")
                        serverOnline == true ->
                            Triple(Icons.Default.CloudDone, AppColors.Good, "Training server connected")
                        serverOnline == false ->
                            Triple(Icons.Default.CloudOff, AppColors.Bad, "Training server unreachable")
                        else ->
                            Triple(Icons.Default.CloudQueue, AppColors.Muted, "No server configured")
                    }
                    Icon(icon, contentDescription = null, tint = tint)
                    Spacer(Modifier.width(12.dp))
                    Text(label, color = tint, modifier = Modifier.weight(1f))
                    IconButton(
                        onClick = { scope.launch { checkServerHealth() } },
                        enabled = !checkingServer,
                    ) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh")
                    }
                }
            }

            Spacer(Modifier.height(16.dp))

            SectionCard(title = "Collection stats") {
                Column {
                    StatRow("Total samples", "${samples.size}")
                    StatRow("Uploaded", "$uploadedCount")
                    StatRow("Pending upload", "$pendingCount")
                }
            }

            Spacer(Modifier.height(16.dp))

            Button(
                onClick = {
                    scope.launch {
                        busyMessage = "Uploading..."
                        val attempted = pendingCount
                        val uploaded = collector.uploadPending()
                        busyMessage = null
                        // Zero of N is a failure, and saying "Uploaded 0
                        // samples" reads like a success with nothing to send.
                        snackbarHostState.showSnackbar(
                            when {
                                uploaded == 0 ->
                                    "Upload failed. Check the server connection and try again."
                                uploaded < attempted ->
                                    "Uploaded $uploaded of $attempted samples. Try again for the rest."
                                uploaded == 1 -> "Uploaded 1 sample"
                                else -> "Uploaded $uploaded samples"
                            },
                        )
                    }
                },
                enabled = pendingCount > 0 && serverUrl.isNotBlank() && hasTrainingKey,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Default.CloudUpload, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text(
                    when {
                        pendingCount == 0 -> "No samples to upload"
                        serverUrl.isBlank() -> "Set a server under Advanced to upload"
                        !hasTrainingKey -> "Add a training API key to upload"
                        pendingCount == 1 -> "Upload 1 sample"
                        else -> "Upload $pendingCount samples"
                    },
                )
            }

            Spacer(Modifier.height(12.dp))

            OutlinedButton(
                onClick = {
                    scope.launch {
                        busyMessage = "Exporting..."
                        val zip = collector.exportTrainingData(File(context.cacheDir, "exports"))
                        busyMessage = null
                        if (zip == null) {
                            snackbarHostState.showSnackbar("Export failed — no samples to export")
                        } else {
                            context.startActivity(
                                Intent.createChooser(
                                    container.videoLibrary.shareIntent(zip, "application/zip")
                                        .putExtra(
                                            Intent.EXTRA_SUBJECT,
                                            "Disc training data export",
                                        ),
                                    "Share training data",
                                ),
                            )
                        }
                    }
                },
                enabled = samples.isNotEmpty(),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Default.FolderZip, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text(if (samples.size == 1) "Export 1 sample" else "Export ${samples.size} samples")
            }

            Spacer(Modifier.height(24.dp))

            SectionCard {
                Column {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(bottom = if (advancedExpanded) 12.dp else 0.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("Advanced", fontWeight = FontWeight.Bold)
                        TextButton(onClick = { advancedExpanded = !advancedExpanded }) {
                            Text(if (advancedExpanded) "Hide" else "Show")
                        }
                    }

                    if (advancedExpanded) {
                        OutlinedTextField(
                            value = serverUrlDraft,
                            onValueChange = { serverUrlDraft = it },
                            label = { Text("Custom server (optional)") },
                            placeholder = { Text(TrainingDataRepository.DEFAULT_SERVER_URL) },
                            supportingText = { Text("Save after editing") },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Spacer(Modifier.height(8.dp))
                        OutlinedButton(
                            onClick = {
                                training.setServerUrl(serverUrlDraft.trim())
                                hasTrainingKey = training.hasApiKey
                                scope.launch {
                                    snackbarHostState.showSnackbar("Server URL saved")
                                    checkServerHealth()
                                }
                            },
                            modifier = Modifier.align(Alignment.End),
                        ) {
                            Icon(Icons.Default.Save, contentDescription = null)
                            Spacer(Modifier.width(8.dp))
                            Text("Save server URL")
                        }
                        Spacer(Modifier.height(12.dp))
                        KeyStatusRow(
                            hasKey = hasTrainingKey,
                            setLabel = "Training API key saved",
                            unsetLabel = "No training API key set; uploads are disabled",
                            setIcon = Icons.Default.Lock,
                            unsetIcon = Icons.Default.LockOpen,
                            onAdd = { trainingKeyDialog = true },
                            onRemove = {
                                training.clearApiKey()
                                hasTrainingKey = false
                                scope.launch {
                                    snackbarHostState.showSnackbar("Training API key removed")
                                }
                            },
                        )
                    }
                }
            }

            Spacer(Modifier.height(24.dp))

            TextButton(
                onClick = { confirmClear = true },
                enabled = samples.isNotEmpty(),
            ) {
                Icon(Icons.Default.DeleteOutline, contentDescription = null, tint = AppColors.Bad)
                Spacer(Modifier.width(8.dp))
                Text("Clear all training data", color = AppColors.Bad)
            }

            TextButton(onClick = onOpenPrivacyPolicy) {
                Icon(Icons.Default.PrivacyTip, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Privacy policy")
            }

            Spacer(Modifier.height(24.dp))
        }
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

    if (trainingKeyDialog) {
        ApiKeyDialog(
            title = "Training API key",
            explanation = "This private server key is stored in the device's encrypted " +
                "storage and is required before uploading training samples.",
            label = "Training API key",
            placeholder = "",
            onDismiss = { trainingKeyDialog = false },
            onSave = { key ->
                training.setApiKey(key)
                hasTrainingKey = training.hasApiKey
                trainingKeyDialog = false
                scope.launch { snackbarHostState.showSnackbar("Training API key saved") }
            },
        )
    }


    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("Clear training data") },
            text = {
                Text("Delete all ${samples.size} training samples? This cannot be undone.")
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmClear = false
                        scope.launch {
                            collector.clearAllData()
                            snackbarHostState.showSnackbar("Training data cleared")
                        }
                    },
                ) {
                    Text("Delete", color = AppColors.Bad)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmClear = false }) { Text("Cancel") }
            },
        )
    }
}


@Composable
private fun StatRow(label: String, value: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun KeyStatusRow(
    hasKey: Boolean,
    setLabel: String,
    unsetLabel: String,
    setIcon: androidx.compose.ui.graphics.vector.ImageVector = Icons.Default.CheckCircle,
    unsetIcon: androidx.compose.ui.graphics.vector.ImageVector = Icons.Default.WarningAmber,
    onAdd: () -> Unit,
    onRemove: () -> Unit,
) {
    val tint: Color = if (hasKey) AppColors.Good else AppColors.Warning
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            if (hasKey) setIcon else unsetIcon,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(8.dp))
        Text(
            if (hasKey) setLabel else unsetLabel,
            style = MaterialTheme.typography.bodySmall,
            color = tint,
            modifier = Modifier.weight(1f),
        )
        if (hasKey) {
            TextButton(onClick = onRemove) { Text("Remove", color = AppColors.Bad) }
        } else {
            Button(onClick = onAdd) { Text("Add key") }
        }
    }
}

@Composable
private fun ApiKeyDialog(
    title: String,
    explanation: String,
    label: String,
    placeholder: String,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
) {
    var key by remember { mutableStateOf("") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column {
                Text(explanation, style = MaterialTheme.typography.bodySmall)
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = key,
                    onValueChange = { key = it },
                    label = { Text(label) },
                    placeholder = { if (placeholder.isNotEmpty()) Text(placeholder) },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { if (key.isNotBlank()) onSave(key) },
                enabled = key.isNotBlank(),
            ) {
                Text("Save")
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
