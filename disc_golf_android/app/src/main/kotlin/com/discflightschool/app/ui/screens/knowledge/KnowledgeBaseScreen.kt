package com.discflightschool.app.ui.screens.knowledge

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccessibilityNew
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.Article
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.components.LoadingState
import com.discflightschool.app.ui.theme.AppColors
import com.discflightschool.core.model.KBArticle
import com.discflightschool.core.model.KBCategory

/** Icons the bundled content refers to by name. */
internal fun categoryIcon(name: String): ImageVector = when (name) {
    "accessibility_new" -> Icons.Default.AccessibilityNew
    "album" -> Icons.Default.Album
    "map" -> Icons.Default.Map
    "psychology" -> Icons.Default.Psychology
    else -> Icons.Default.Article
}

/** The library's front page: one tip, a search entry, and the categories. */
@Composable
fun KnowledgeBaseScreen(
    onBack: () -> Unit,
    onOpenSearch: () -> Unit,
    onOpenCategory: (String) -> Unit,
) {
    val container = LocalAppContainer.current
    val repository = container.knowledgeBaseRepository
    val isLoaded by repository.isLoaded.collectAsStateWithLifecycle()
    var randomTip by remember { mutableStateOf<KBArticle?>(null) }

    LaunchedEffect(Unit) {
        repository.load()
        randomTip = repository.randomTip()
    }

    Scaffold(topBar = { AppTopBar(title = "Knowledge base", onBack = onBack) }) { padding ->
        if (!isLoaded) {
            LoadingState("Loading the research library...", Modifier.padding(padding))
            return@Scaffold
        }

        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            SearchEntry(onClick = onOpenSearch)

            randomTip?.let { tip ->
                Spacer(Modifier.height(16.dp))
                TipCard(
                    tip = tip,
                    citation = tip.sourceIds.firstOrNull()
                        ?.let { repository.study(it)?.citation },
                    accent = AppColors.KnowledgeBase,
                )
            }

            Spacer(Modifier.height(20.dp))

            val categories = repository.categories
            LazyVerticalGrid(
                columns = GridCells.Fixed(2),
                modifier = Modifier.heightIn(max = 1000.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                items(categories.size) { index ->
                    val category = categories[index]
                    CategoryCard(
                        category = category,
                        articleCount = repository.articleCount(category.id),
                        studyCount = repository.studyCount(category.id),
                        onClick = { onOpenCategory(category.id) },
                    )
                }
            }

            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun SearchEntry(onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Color.White.copy(alpha = 0.06f), RoundedCornerShape(12.dp))
            .border(
                1.dp,
                AppColors.KnowledgeBase.copy(alpha = 0.32f),
                RoundedCornerShape(12.dp),
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Default.Search, contentDescription = null, tint = AppColors.KnowledgeBase)
        Spacer(Modifier.width(12.dp))
        Text("Ask a question...", color = AppColors.Muted)
        Spacer(Modifier.weight(1f))
        Icon(
            Icons.Default.AutoAwesome,
            contentDescription = null,
            tint = AppColors.KnowledgeBase,
            modifier = Modifier.size(20.dp),
        )
    }
}

@Composable
internal fun TipCard(tip: KBArticle, citation: String?, accent: Color) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(accent.copy(alpha = 0.14f), RoundedCornerShape(12.dp))
            .border(1.dp, accent.copy(alpha = 0.3f), RoundedCornerShape(12.dp))
            .padding(16.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Icon(
                Icons.Default.Lightbulb,
                contentDescription = null,
                tint = AppColors.Warning,
                modifier = Modifier.size(20.dp),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                tip.question,
                fontWeight = FontWeight.Bold,
                color = accent,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
        Spacer(Modifier.height(8.dp))
        Text(tip.answer, style = MaterialTheme.typography.bodyMedium)
        if (citation != null) {
            Spacer(Modifier.height(8.dp))
            Text(
                "— $citation",
                style = MaterialTheme.typography.labelSmall,
                color = accent,
                fontStyle = FontStyle.Italic,
            )
        }
    }
}

@Composable
private fun CategoryCard(
    category: KBCategory,
    articleCount: Int,
    studyCount: Int,
    onClick: () -> Unit,
) {
    val color = Color(category.colorValue)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(1.15f)
            .background(color.copy(alpha = 0.14f), RoundedCornerShape(12.dp))
            .border(1.dp, color.copy(alpha = 0.32f), RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .padding(16.dp),
    ) {
        Box(
            modifier = Modifier
                .background(color.copy(alpha = 0.2f), RoundedCornerShape(10.dp))
                .padding(10.dp),
        ) {
            Icon(
                categoryIcon(category.iconName),
                contentDescription = null,
                tint = color,
                modifier = Modifier.size(28.dp),
            )
        }
        Spacer(Modifier.weight(1f))
        Text(
            category.name,
            fontWeight = FontWeight.Bold,
            style = MaterialTheme.typography.bodyMedium,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            "$studyCount ${if (studyCount == 1) "study" else "studies"} · $articleCount tips",
            style = MaterialTheme.typography.labelSmall,
            color = AppColors.Muted,
        )
    }
}
