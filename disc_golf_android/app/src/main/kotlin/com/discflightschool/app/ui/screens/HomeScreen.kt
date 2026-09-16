package com.discflightschool.app.ui.screens

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
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
import androidx.compose.material.icons.automirrored.filled.ArrowForwardIos
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.AccessibilityNew
import androidx.compose.material.icons.filled.Casino
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.TrackChanges
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.discflightschool.app.R
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.theme.AppColors

/** The four things the app does, and the two places it keeps them. */
@Composable
fun HomeScreen(
    onOpenFlightTracker: () -> Unit,
    onOpenFormCoach: () -> Unit,
    onOpenRoulette: () -> Unit,
    onOpenKnowledgeBase: () -> Unit,
    onOpenGallery: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    Scaffold(
        topBar = {
            AppTopBar(title = "Disc Flight School") {
                IconButton(onClick = onOpenGallery) {
                    Icon(Icons.Default.VideoLibrary, contentDescription = "Flight path gallery")
                }
                IconButton(onClick = onOpenSettings) {
                    Icon(Icons.Default.Settings, contentDescription = "Training settings")
                }
            }
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(24.dp))
            Image(
                painter = painterResource(R.drawable.ic_disc_golf_basket),
                contentDescription = null,
                modifier = Modifier.size(80.dp),
            )
            Spacer(Modifier.height(40.dp))
            Text(
                "Welcome to Disc Flight School",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(40.dp))

            FeatureCard(
                title = "Flight Tracker",
                description = "Track and analyze disc flight paths",
                icon = Icons.Default.TrackChanges,
                accent = AppColors.FlightTracker,
                onClick = onOpenFlightTracker,
            )
            Spacer(Modifier.height(16.dp))
            FeatureCard(
                title = "Form Coach",
                description = "Analyze and improve your throwing form",
                icon = Icons.Default.AccessibilityNew,
                accent = AppColors.FormCoach,
                onClick = onOpenFormCoach,
            )
            Spacer(Modifier.height(16.dp))
            FeatureCard(
                title = "Disc Roulette",
                description = "Random shot challenges and scored rounds",
                icon = Icons.Default.Casino,
                accent = AppColors.Roulette,
                onClick = onOpenRoulette,
            )
            Spacer(Modifier.height(16.dp))
            FeatureCard(
                title = "Knowledge Base",
                description = "Research-backed tips and AI-powered FAQ",
                icon = Icons.AutoMirrored.Filled.MenuBook,
                accent = AppColors.KnowledgeBase,
                onClick = onOpenKnowledgeBase,
            )
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun FeatureCard(
    title: String,
    description: String,
    icon: ImageVector,
    accent: Color,
    onClick: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = AppColors.Surface,
        tonalElevation = 4.dp,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier
                .clickable(onClick = onClick)
                .padding(20.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Surface(
                shape = RoundedCornerShape(12.dp),
                color = accent.copy(alpha = 0.2f),
            ) {
                Icon(
                    icon,
                    contentDescription = null,
                    tint = accent,
                    modifier = Modifier
                        .padding(12.dp)
                        .size(32.dp),
                )
            }
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    title,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    description,
                    style = MaterialTheme.typography.bodySmall,
                    color = AppColors.Muted,
                )
            }
            Icon(
                Icons.AutoMirrored.Filled.ArrowForwardIos,
                contentDescription = null,
                tint = AppColors.Muted,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}
