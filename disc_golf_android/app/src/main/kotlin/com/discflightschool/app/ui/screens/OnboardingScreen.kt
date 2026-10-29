package com.discflightschool.app.ui.screens

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.AccessibilityNew
import androidx.compose.material.icons.filled.Casino
import androidx.compose.material.icons.filled.TrackChanges
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.R
import com.discflightschool.app.ui.theme.AppColors
import kotlinx.coroutines.launch

private data class OnboardingPage(
    /** Null on the welcome page, which shows the app's own basket mark. */
    val icon: ImageVector?,
    val title: String,
    val body: String,
)

private val onboardingPages = listOf(
    OnboardingPage(
        icon = null,
        title = "Welcome to\nDisc Flight School",
        body = "Your personal disc golf coach — analyze your form, track disc flight, " +
            "and practice smarter with guided challenges.",
    ),
    OnboardingPage(
        icon = Icons.Default.AccessibilityNew,
        title = "Form Coach",
        body = "Record a throw and let on-device pose detection score your technique. " +
            "Compare against pro baselines phase by phase and get targeted cues to fix " +
            "the angles that matter most.",
    ),
    OnboardingPage(
        icon = Icons.Default.TrackChanges,
        title = "Flight Tracker",
        body = "Let the detector find the disc, or place markers yourself frame by frame " +
            "to map the exact flight path. Zoom in for precise placement, draw a target " +
            "line, and export the trajectory.",
    ),
    OnboardingPage(
        icon = Icons.Default.Casino,
        title = "Disc Roulette",
        body = "Spin for a random disc, shot shape, and hindrance. Play a full scored " +
            "round where every stroke is weighted by how hard the challenge was.",
    ),
    OnboardingPage(
        icon = Icons.AutoMirrored.Filled.MenuBook,
        title = "Knowledge Base",
        body = "Browse tips, drills, and technique articles — or ask a question and get " +
            "an answer grounded in the peer-reviewed research bundled with the app.",
    ),
)

/**
 * The first-launch walkthrough.
 *
 * Shown once. Completion is recorded whether the user reads it or skips it, so
 * it never reappears on a later launch.
 */
@Composable
fun OnboardingScreen(onFinished: () -> Unit) {
    val container = LocalAppContainer.current
    val pagerState = rememberPagerState(pageCount = { onboardingPages.size })
    val scope = rememberCoroutineScope()

    fun finish() {
        container.appPreferences.onboardingComplete = true
        onFinished()
    }

    Box(Modifier.fillMaxSize()) {
        HorizontalPager(state = pagerState, modifier = Modifier.fillMaxSize()) { page ->
            OnboardingPageContent(onboardingPages[page])
        }

        Row(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .padding(horizontal = 24.dp, vertical = 36.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val isLast = pagerState.currentPage == onboardingPages.lastIndex

            // The skip slot keeps its width on the last page, so the dots and
            // the main button don't shift, but there is nothing to focus.
            Box(Modifier.width(72.dp)) {
                if (!isLast) {
                    TextButton(onClick = { finish() }) {
                        Text("Skip", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.clearAndSetSemantics {
                    contentDescription =
                        "Page ${pagerState.currentPage + 1} of ${onboardingPages.size}"
                },
            ) {
                repeat(onboardingPages.size) { index ->
                    val width by animateDpAsState(
                        targetValue = if (index == pagerState.currentPage) 18.dp else 8.dp,
                        animationSpec = tween(250),
                        label = "dotWidth",
                    )
                    Box(
                        modifier = Modifier
                            .padding(horizontal = 4.dp)
                            .size(width = width, height = 8.dp)
                            .background(
                                if (index == pagerState.currentPage) {
                                    AppColors.Accent
                                } else {
                                    Color.White.copy(alpha = 0.24f)
                                },
                                RoundedCornerShape(4.dp),
                            ),
                    )
                }
            }

            Button(
                onClick = {
                    if (isLast) {
                        finish()
                    } else {
                        scope.launch { pagerState.animateScrollToPage(pagerState.currentPage + 1) }
                    }
                },
                shape = RoundedCornerShape(20.dp),
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
            ) {
                Text(if (isLast) "Get started" else "Next", color = MaterialTheme.colorScheme.background)
            }
        }
    }
}

@Composable
private fun OnboardingPageContent(page: OnboardingPage) {
    // Centred when it fits, scrollable when a large font size makes it not:
    // the minimum height keeps the centring, the scroll keeps the overflow
    // reachable instead of clipped under the button row.
    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .background(AppColors.Background),
    ) {
        Column(
            modifier = Modifier
                .verticalScroll(rememberScrollState())
                .heightIn(min = maxHeight)
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(start = 32.dp, top = 48.dp, end = 32.dp, bottom = 120.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Box(
                modifier = Modifier
                    .size(120.dp)
                    .background(Color.White.copy(alpha = 0.06f), CircleShape)
                    .border(2.dp, AppColors.Accent, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                if (page.icon != null) {
                    Icon(
                        page.icon,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(64.dp),
                    )
                } else {
                    Image(
                        painter = painterResource(R.drawable.ic_disc_golf_basket),
                        contentDescription = null,
                        modifier = Modifier.size(72.dp),
                    )
                }
            }
            Spacer(Modifier.height(40.dp))
            Text(
                page.title,
                modifier = Modifier.semantics { heading() },
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(20.dp))
            Text(
                page.body,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
    }
}
