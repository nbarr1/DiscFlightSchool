package com.discflightschool.app.ui.screens

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
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
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.discflightschool.app.R
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.components.NavigationCard
import com.discflightschool.app.ui.components.readableWidth
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
                .readableWidth()
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(16.dp))
            Image(
                painter = painterResource(R.drawable.ic_disc_golf_basket),
                contentDescription = null,
                modifier = Modifier.size(80.dp),
            )
            Spacer(Modifier.height(24.dp))
            // The app bar already names the app; the headline says what the
            // screen is for instead of repeating it.
            Text(
                "What do you want to work on?",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
                modifier = Modifier.semantics { heading() },
            )
            Spacer(Modifier.height(32.dp))

            NavigationCard(
                title = "Flight Tracker",
                description = "Track and analyze disc flight paths",
                icon = Icons.Default.TrackChanges,
                accent = AppColors.FlightTracker,
                onClick = onOpenFlightTracker,
            )
            Spacer(Modifier.height(16.dp))
            NavigationCard(
                title = "Form Coach",
                description = "Analyze and improve your throwing form",
                icon = Icons.Default.AccessibilityNew,
                accent = AppColors.FormCoach,
                onClick = onOpenFormCoach,
            )
            Spacer(Modifier.height(16.dp))
            NavigationCard(
                title = "Disc Roulette",
                description = "Random shot challenges and scored rounds",
                icon = Icons.Default.Casino,
                accent = AppColors.Roulette,
                onClick = onOpenRoulette,
            )
            Spacer(Modifier.height(16.dp))
            NavigationCard(
                title = "Knowledge Base",
                description = "Research-backed tips and FAQ",
                icon = Icons.AutoMirrored.Filled.MenuBook,
                accent = AppColors.KnowledgeBase,
                onClick = onOpenKnowledgeBase,
            )
            Spacer(Modifier.height(24.dp))
        }
    }
}
