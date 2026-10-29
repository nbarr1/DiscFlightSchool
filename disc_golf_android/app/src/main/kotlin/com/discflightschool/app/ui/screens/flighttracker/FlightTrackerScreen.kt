package com.discflightschool.app.ui.screens.flighttracker

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.UploadFile
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.components.NavigationCard
import com.discflightschool.app.ui.components.readableWidth
import com.discflightschool.app.ui.components.rememberVideoPickers
import com.discflightschool.app.ui.theme.AppColors
import kotlinx.coroutines.launch

/** Brings a clip in, then hands it to the trimmer before tracking starts. */
@Composable
fun FlightTrackerScreen(onBack: () -> Unit, onVideoSelected: () -> Unit) {
    val container = LocalAppContainer.current
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }

    val pickers = rememberVideoPickers(
        onVideoReady = { path ->
            container.workbench.startFlightSession(path)
            onVideoSelected()
        },
        onFailed = { message -> scope.launch { snackbarHostState.showSnackbar(message) } },
    )

    Scaffold(
        topBar = { AppTopBar(title = "Flight Tracker", onBack = onBack) },
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
            Text(
                "Track disc flight",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(8.dp))
            Text(
                "Record or upload a video to map the flight path.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(24.dp))

            NavigationCard(
                title = "Record video",
                description = "Use the camera to record a throw",
                icon = Icons.Default.Videocam,
                accent = AppColors.Bad,
                onClick = { pickers.recordVideo() },
            )
            Spacer(Modifier.height(16.dp))
            NavigationCard(
                title = "Upload video",
                description = "Select a video from your device",
                icon = Icons.Default.UploadFile,
                accent = AppColors.FlightTracker,
                onClick = { pickers.pickFromLibrary() },
            )
        }
    }
}
