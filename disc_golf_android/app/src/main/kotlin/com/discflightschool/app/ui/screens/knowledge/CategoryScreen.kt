package com.discflightschool.app.ui.screens.knowledge

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.components.LoadingState
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

    val category = repository.categories.firstOrNull { it.id == categoryId }
    if (category == null) {
        Scaffold(topBar = { AppTopBar(title = "Category", onBack = onBack) }) { padding ->
            LoadingState("Loading...", Modifier.padding(padding))
        }
        return
    }

    val color = Color(category.colorValue)
    val tips = repository.articles(category = categoryId, type = "tip")
    val faqs = repository.articles(category = categoryId, type = "faq")

    Scaffold(topBar = { AppTopBar(title = category.name, onBack = onBack) }) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            Text(
                category.description,
                style = MaterialTheme.typography.bodyMedium,
                color = AppColors.Muted,
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
                        citation = tip.sourceIds.firstOrNull()
                            ?.let { repository.study(it)?.citation },
                        accent = color,
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
                    FaqRow(faq, color) { onOpenArticle(faq.id) }
                    Spacer(Modifier.height(4.dp))
                }
            }

            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun FaqRow(article: KBArticle, accent: Color, onClick: () -> Unit) {
    Surface(
        color = AppColors.Surface,
        shape = RoundedCornerShape(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier
                .clickable(onClick = onClick)
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

    val article = repository.articles.firstOrNull { it.id == articleId }
    if (article == null) {
        Scaffold(topBar = { AppTopBar(title = "FAQ", onBack = onBack) }) { padding ->
            LoadingState("Loading...", Modifier.padding(padding))
        }
        return
    }

    Scaffold(topBar = { AppTopBar(title = "FAQ detail", onBack = onBack) }) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            Text(
                article.question,
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

            val sources = article.sourceIds.mapNotNull { repository.study(it) }
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
            color = AppColors.Muted,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            study.filename,
            style = MaterialTheme.typography.labelSmall,
            color = AppColors.Muted,
            fontStyle = FontStyle.Italic,
        )
    }
}
