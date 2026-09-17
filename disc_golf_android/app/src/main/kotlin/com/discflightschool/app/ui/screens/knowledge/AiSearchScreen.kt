package com.discflightschool.app.ui.screens.knowledge

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
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AssistChip
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.theme.AppColors
import kotlinx.coroutines.launch

/** One question and the answer it got. */
private data class QaPair(
    val question: String,
    val answer: String? = null,
    val isAi: Boolean = false,
)

/**
 * Question and answer over the bundled research.
 *
 * Local keyword search is the default and needs nothing configured. With an
 * Anthropic key saved, the toggle sends the question to Claude instead,
 * grounded in the same library.
 */
@Composable
fun AiSearchScreen(onBack: () -> Unit) {
    val container = LocalAppContainer.current
    val repository = container.knowledgeBaseRepository
    val hasApiKey by repository.hasApiKey.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val listState = rememberLazyListState()

    val history = remember { mutableStateListOf<QaPair>() }
    var input by remember { mutableStateOf("") }
    var isLoading by remember { mutableStateOf(false) }
    var useAi by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { repository.load() }

    fun ask(question: String) {
        val trimmed = question.trim()
        if (trimmed.isEmpty() || isLoading) return

        val viaAi = useAi && hasApiKey
        history += QaPair(question = trimmed)
        input = ""
        isLoading = viaAi

        scope.launch {
            val answer = if (viaAi) {
                container.aiSearchClient.ask(
                    question = trimmed,
                    apiKey = repository.apiKey(),
                    studies = repository.studies,
                )
            } else {
                repository.searchLocal(trimmed)
            }
            history[history.lastIndex] = QaPair(trimmed, answer, viaAi)
            isLoading = false
            listState.animateScrollToItem(history.lastIndex)
        }
    }

    Scaffold(
        topBar = { AppTopBar(title = "Ask about disc golf", onBack = onBack) },
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize()
                .imePadding(),
        ) {
            Box(Modifier.weight(1f)) {
                if (history.isEmpty()) {
                    EmptySearchState(onSuggestion = { ask(it) })
                } else {
                    LazyColumn(
                        state = listState,
                        contentPadding = PaddingValues(16.dp),
                        modifier = Modifier.fillMaxSize(),
                    ) {
                        itemsIndexed(history) { _, qa -> QaBubble(qa) }
                    }
                }
            }

            if (isLoading) {
                Row(
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator(
                        strokeWidth = 2.dp,
                        color = AppColors.KnowledgeBase,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        "Asking Claude...",
                        color = AppColors.KnowledgeBase,
                        style = MaterialTheme.typography.labelMedium,
                    )
                }
            }

            InputBar(
                value = input,
                onValueChange = { input = it },
                onSend = { ask(input) },
                sendEnabled = !isLoading,
                showAiToggle = hasApiKey,
                useAi = useAi,
                onUseAiChange = { useAi = it },
            )
        }
    }
}

@Composable
private fun EmptySearchState(onSuggestion: (String) -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            Icons.Default.Search,
            contentDescription = null,
            tint = AppColors.KnowledgeBase,
            modifier = Modifier.size(48.dp),
        )
        Spacer(Modifier.height(16.dp))
        Text(
            "Search the research",
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            "Get answers backed by the peer-reviewed disc golf studies bundled with the app.",
            style = MaterialTheme.typography.bodyMedium,
            color = AppColors.Muted,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(24.dp))
        listOf(
            "What muscles matter most for backhand?",
            "Where should my thumb be on the disc?",
            "How do pros putt differently?",
            "What speed should I throw at my level?",
        ).forEach { suggestion ->
            AssistChip(
                onClick = { onSuggestion(suggestion) },
                label = { Text(suggestion, style = MaterialTheme.typography.labelMedium) },
                modifier = Modifier.padding(vertical = 4.dp),
            )
        }
    }
}

@Composable
private fun QaBubble(qa: QaPair) {
    Column(Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.End,
        ) {
            Box(
                modifier = Modifier
                    .padding(start = 48.dp, bottom = 8.dp)
                    .background(AppColors.TopBar, RoundedCornerShape(12.dp))
                    .padding(12.dp),
            ) {
                Text(qa.question, style = MaterialTheme.typography.bodyMedium)
            }
        }

        qa.answer?.let { answer ->
            Column(
                modifier = Modifier
                    .padding(end = 48.dp, bottom = 16.dp)
                    .background(
                        AppColors.KnowledgeBase.copy(alpha = 0.12f),
                        RoundedCornerShape(12.dp),
                    )
                    .border(
                        1.dp,
                        AppColors.KnowledgeBase.copy(alpha = 0.25f),
                        RoundedCornerShape(12.dp),
                    )
                    .padding(14.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        if (qa.isAi) {
                            Icons.Default.AutoAwesome
                        } else {
                            Icons.AutoMirrored.Filled.MenuBook
                        },
                        contentDescription = null,
                        tint = AppColors.KnowledgeBase,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        if (qa.isAi) "AI answer" else "Research says",
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.Bold,
                        color = AppColors.KnowledgeBase,
                    )
                }
                Spacer(Modifier.height(8.dp))
                Text(answer, style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

@Composable
private fun InputBar(
    value: String,
    onValueChange: (String) -> Unit,
    onSend: () -> Unit,
    sendEnabled: Boolean,
    showAiToggle: Boolean,
    useAi: Boolean,
    onUseAiChange: (Boolean) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(AppColors.Background)
            .padding(12.dp),
    ) {
        if (showAiToggle) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 8.dp),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "Local",
                    style = MaterialTheme.typography.labelMedium,
                    color = if (useAi) AppColors.Muted else AppColors.KnowledgeBase,
                )
                Spacer(Modifier.width(6.dp))
                Switch(checked = useAi, onCheckedChange = onUseAiChange)
                Spacer(Modifier.width(6.dp))
                Icon(
                    Icons.Default.AutoAwesome,
                    contentDescription = null,
                    tint = if (useAi) AppColors.Roulette else AppColors.Muted,
                    modifier = Modifier.size(14.dp),
                )
                Spacer(Modifier.width(3.dp))
                Text(
                    "AI",
                    style = MaterialTheme.typography.labelMedium,
                    color = if (useAi) AppColors.Roulette else AppColors.Muted,
                )
            }
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = value,
                onValueChange = onValueChange,
                placeholder = { Text("Ask a question...") },
                shape = RoundedCornerShape(24.dp),
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { onSend() }),
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(8.dp))
            IconButton(onClick = onSend, enabled = sendEnabled) {
                Icon(
                    Icons.AutoMirrored.Filled.Send,
                    contentDescription = "Send",
                    tint = AppColors.KnowledgeBase,
                )
            }
        }
    }
}
