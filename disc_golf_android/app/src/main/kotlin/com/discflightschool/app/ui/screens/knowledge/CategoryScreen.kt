package com.discflightschool.app.ui.screens.knowledge

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.components.LoadingState
import com.discflightschool.app.ui.components.readableWidth
import com.discflightschool.app.ui.theme.AppColors
import com.discflightschool.core.model.KBArticle
import com.discflightschool.core.model.KBStudy

/** Everything the library has on one topic: tips first, then the FAQs. */
@Composable
fun CategoryScreen(
    categoryId: String,
    onBack: () -> Unit,
    onOpenArticle: (String) -> Unit,
) {
    val container = LocalAppContainer.current
    val repository = container.knowledgeBaseRepository

    LaunchedEffect(Unit) { repository.load() }

    // Collected, not read once: on a back stack restored after process death
    // this screen composes before the content is parsed, and a plain read would
    // leave it on "Loading..." for good.
    val content by repository.content.collectAsStateWithLifecycle()

    val category = content.categories.firstOrNull { it.id == categoryId }
    if (category == null) {
        Scaffold(topBar = { AppTopBar(title = "Category", onBack = onBack) }) { padding ->
            LoadingState("Loading...", Modifier.padding(padding))
        }
        return
    }

    val color = Color(category.colorValue)
    val tips = repository.articles(category = categoryId, type = "tip")
    val faqs = repository.articles(category = categoryId, type = "faq")

    // On a tablet the list and the answer sit side by side; on a phone a tap
    // opens the answer as its own screen.
    var selectedArticleId by rememberSaveable { mutableStateOf<String?>(null) }

    Scaffold(topBar = { AppTopBar(title = category.name, onBack = onBack) }) { padding ->
        BoxWithConstraints(
            Modifier
                .padding(padding)
                .fillMaxSize(),
        ) {
            val twoPane = maxWidth >= TWO_PANE_MIN_WIDTH
            val list: @Composable (Modifier) -> Unit = { modifier ->
                CategoryContent(
                    description = category.description,
                    tips = tips,
                    faqs = faqs,
                    accent = color,
                    citationFor = { tip ->
                        tip.sourceIds.firstOrNull()?.let { repository.study(it)?.citation }
                    },
                    selectedArticleId = if (twoPane) selectedArticleId else null,
                    onOpenArticle = { id ->
                        if (twoPane) selectedArticleId = id else onOpenArticle(id)
                    },
                    modifier = modifier,
                )
            }
            if (twoPane) {
                Row(Modifier.fillMaxSize()) {
                    list(
                        Modifier
                            .weight(0.45f)
                            .fillMaxHeight(),
                    )
                    VerticalDivider()
                    val article = content.articles.firstOrNull { it.id == selectedArticleId }
                    if (article == null) {
                        Text(
                            "Choose a question to read the answer here.",
                            modifier = Modifier
                                .weight(0.55f)
                                .padding(32.dp),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    } else {
                        ArticleContent(
                            article = article,
                            sources = article.sourceIds.mapNotNull { repository.study(it) },
                            modifier = Modifier
                                .weight(0.55f)
                                .fillMaxHeight(),
                        )
                    }
                }
            } else {
                list(Modifier.fillMaxSize())
            }
        }
    }
}

/** The category's description, its tips, and its FAQ list, scrolling as one column. */
@Composable
private fun CategoryContent(
    description: String,
    tips: List<KBArticle>,
    faqs: List<KBArticle>,
    accent: Color,
    citationFor: (KBArticle) -> String?,
    selectedArticleId: String?,
    onOpenArticle: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .verticalScroll(rememberScrollState())
            .readableWidth()
            .padding(16.dp),
    ) {
        Text(
            description,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        if (tips.isNotEmpty()) {
            Spacer(Modifier.height(20.dp))
            Text(
                "Tips",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(8.dp))
            tips.forEach { tip ->
                TipCard(
                    tip = tip,
                    citation = citationFor(tip),
                    accent = accent,
                )
                Spacer(Modifier.height(8.dp))
            }
        }

        if (faqs.isNotEmpty()) {
            Spacer(Modifier.height(16.dp))
            Text(
                "Frequently asked questions",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(8.dp))
            faqs.forEach { faq ->
                FaqRow(faq, accent, selected = faq.id == selectedArticleId) { onOpenArticle(faq.id) }
                Spacer(Modifier.height(4.dp))
            }
        }

        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun FaqRow(article: KBArticle, accent: Color, selected: Boolean, onClick: () -> Unit) {
    Surface(
        color = if (selected) accent.copy(alpha = 0.16f) else MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier
                .selectable(selected = selected, onClick = onClick)
                .padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                article.question,
                modifier = Modifier.weight(1f),
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
            )
            Icon(Icons.Default.ChevronRight, contentDescription = null, tint = accent)
        }
    }
}

/** One FAQ in full, with its key findings and the studies behind it. */
@Composable
fun ArticleDetailScreen(articleId: String, onBack: () -> Unit) {
    val container = LocalAppContainer.current
    val repository = container.knowledgeBaseRepository

    LaunchedEffect(Unit) { repository.load() }

    val content by repository.content.collectAsStateWithLifecycle()

    val article = content.articles.firstOrNull { it.id == articleId }
    if (article == null) {
        Scaffold(topBar = { AppTopBar(title = "FAQ", onBack = onBack) }) { padding ->
            LoadingState("Loading...", Modifier.padding(padding))
        }
        return
    }

    Scaffold(topBar = { AppTopBar(title = "Answer", onBack = onBack) }) { padding ->
        ArticleContent(
            article = article,
            sources = article.sourceIds.mapNotNull { repository.study(it) },
            modifier = Modifier
                .padding(padding)
                .fillMaxSize(),
        )
    }
}

/** One answer in full: the question, the answer, key findings, and sources. */
@Composable
private fun ArticleContent(
    article: KBArticle,
    sources: List<KBStudy>,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .verticalScroll(rememberScrollState())
            .readableWidth()
            .padding(16.dp),
    ) {
        Text(
            article.question,
            modifier = Modifier.semantics { heading() },
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(16.dp))
        Text(article.answer, style = MaterialTheme.typography.bodyLarge)

        if (article.keyFindings.isNotEmpty()) {
            Spacer(Modifier.height(20.dp))
            Text(
                "Key findings",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(8.dp))
            article.keyFindings.forEach { finding ->
                Row(Modifier.padding(bottom = 8.dp)) {
                    Text("  •  ", fontWeight = FontWeight.Bold)
                    Text(finding, style = MaterialTheme.typography.bodyMedium)
                }
            }
        }

        if (sources.isNotEmpty()) {
            Spacer(Modifier.height(24.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.AutoMirrored.Filled.MenuBook,
                    contentDescription = null,
                    tint = AppColors.KnowledgeBase,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    "Sources",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                )
            }
            Spacer(Modifier.height(8.dp))
            sources.forEach { study ->
                SourceCard(study)
                Spacer(Modifier.height(8.dp))
            }
        }

        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun SourceCard(study: KBStudy) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(
                AppColors.KnowledgeBase.copy(alpha = 0.12f),
                RoundedCornerShape(8.dp),
            )
            .border(
                1.dp,
                AppColors.KnowledgeBase.copy(alpha = 0.25f),
                RoundedCornerShape(8.dp),
            )
            .padding(12.dp),
    ) {
        Text(
            study.citation,
            fontWeight = FontWeight.Bold,
            color = AppColors.KnowledgeBase,
            style = MaterialTheme.typography.bodyMedium,
        )
        Spacer(Modifier.height(4.dp))
        Text(study.title, style = MaterialTheme.typography.bodyMedium)
        Spacer(Modifier.height(6.dp))
        Text(
            study.summary,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            study.filename,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontStyle = FontStyle.Italic,
        )
    }
}

/** Material's expanded width class: room for the list and the answer side by side. */
private val TWO_PANE_MIN_WIDTH = 840.dp
