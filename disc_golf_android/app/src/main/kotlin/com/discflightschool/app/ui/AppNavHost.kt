package com.discflightschool.app.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.ui.screens.HomeScreen
import com.discflightschool.app.ui.screens.OnboardingScreen
import com.discflightschool.app.ui.screens.flighttracker.FlightPlayerScreen
import com.discflightschool.app.ui.screens.flighttracker.FlightTrackerScreen
import com.discflightschool.app.ui.screens.formcoach.FormCoachScreen
import com.discflightschool.app.ui.screens.formcoach.FormHistoryScreen
import com.discflightschool.app.ui.screens.formcoach.PhaseComparisonScreen
import com.discflightschool.app.ui.screens.formcoach.PhaseFrameSelectorScreen
import com.discflightschool.app.ui.screens.formcoach.PoseCorrectionScreen
import com.discflightschool.app.ui.screens.formcoach.PostureAnalysisScreen
import com.discflightschool.app.ui.screens.formcoach.VideoTrimScreen
import com.discflightschool.app.ui.screens.gallery.VideoGalleryScreen
import com.discflightschool.app.ui.screens.knowledge.AiSearchScreen
import com.discflightschool.app.ui.screens.knowledge.ArticleDetailScreen
import com.discflightschool.app.ui.screens.knowledge.CategoryScreen
import com.discflightschool.app.ui.screens.knowledge.KnowledgeBaseScreen
import com.discflightschool.app.ui.screens.roulette.PlayRoundScreen
import com.discflightschool.app.ui.screens.roulette.RouletteHistoryScreen
import com.discflightschool.app.ui.screens.roulette.RouletteScreen
import com.discflightschool.app.ui.screens.roulette.ScorecardScreen
import com.discflightschool.app.ui.screens.roulette.StartRoundScreen
import com.discflightschool.app.ui.screens.settings.PrivacyPolicyScreen
import com.discflightschool.app.ui.screens.settings.TrainingSettingsScreen

/**
 * The single navigation graph for the app.
 *
 * Three of the flows replace the screen they came from rather than stacking on
 * it — trim to tracker, round setup to play, play to scorecard — because going
 * back to a trimmer whose result has already been consumed, or to a round that
 * has just been scored, only ever produces a confusing half-state.
 */
@Composable
fun AppNavHost(startOnHome: Boolean) {
    val navController = rememberNavController()
    val container = LocalAppContainer.current
    val workbench = container.workbench

    NavHost(
        navController = navController,
        startDestination = if (startOnHome) Destinations.HOME else Destinations.ONBOARDING,
    ) {
        composable(Destinations.ONBOARDING) {
            OnboardingScreen(
                onFinished = {
                    navController.navigate(Destinations.HOME) {
                        popUpTo(Destinations.ONBOARDING) { inclusive = true }
                    }
                },
            )
        }

        composable(Destinations.HOME) {
            HomeScreen(
                onOpenFlightTracker = { navController.navigate(Destinations.FLIGHT_TRACKER) },
                onOpenFormCoach = { navController.navigate(Destinations.FORM_COACH) },
                onOpenRoulette = { navController.navigate(Destinations.ROULETTE) },
                onOpenKnowledgeBase = { navController.navigate(Destinations.KNOWLEDGE_BASE) },
                onOpenGallery = { navController.navigate(Destinations.VIDEO_GALLERY) },
                onOpenSettings = { navController.navigate(Destinations.TRAINING_SETTINGS) },
            )
        }

        // ── Flight Tracker ───────────────────────────────────────────────

        composable(Destinations.FLIGHT_TRACKER) {
            FlightTrackerScreen(
                onBack = { navController.popBackStack() },
                onVideoSelected = { navController.navigate(Destinations.FLIGHT_TRIM) },
            )
        }

        composable(Destinations.FLIGHT_TRIM) {
            WithVideo(workbench.flightVideoPath, onMissing = { navController.popBackStack() }) { path ->
                VideoTrimScreen(
                    videoPath = path,
                    title = "Trim throw",
                    confirmLabel = "Track flight",
                    onBack = { navController.popBackStack() },
                    onConfirm = { startMs, endMs, _ ->
                        workbench.flightTrimStartMs = startMs
                        workbench.flightTrimEndMs = endMs
                        navController.navigate(Destinations.FLIGHT_PLAYER) {
                            popUpTo(Destinations.FLIGHT_TRIM) { inclusive = true }
                        }
                    },
                )
            }
        }

        composable(Destinations.FLIGHT_PLAYER) {
            FlightPlayerScreen(onBack = { navController.popBackStack() })
        }

        composable(Destinations.VIDEO_GALLERY) {
            VideoGalleryScreen(onBack = { navController.popBackStack() })
        }

        // ── Form Coach ───────────────────────────────────────────────────

        composable(Destinations.FORM_COACH) {
            FormCoachScreen(
                onBack = { navController.popBackStack() },
                onOpenHistory = { navController.navigate(Destinations.FORM_HISTORY) },
                onVideoSelected = { navController.navigate(Destinations.FORM_TRIM) },
                onOpenAnalysis = { navController.navigate(Destinations.POSTURE_ANALYSIS) },
            )
        }

        composable(Destinations.FORM_TRIM) {
            WithVideo(workbench.formVideoPath, onMissing = { navController.popBackStack() }) { path ->
                VideoTrimScreen(
                    videoPath = path,
                    onBack = { navController.popBackStack() },
                    onConfirm = { startMs, endMs, frameCount ->
                        workbench.analysisStartMs = startMs
                        workbench.analysisEndMs = endMs
                        workbench.analysisFrameCount = frameCount
                        navController.navigate(Destinations.PHASE_FRAME_SELECTOR) {
                            popUpTo(Destinations.FORM_TRIM) { inclusive = true }
                        }
                    },
                )
            }
        }

        composable(Destinations.PHASE_FRAME_SELECTOR) {
            PhaseFrameSelectorScreen(
                onBack = { navController.popBackStack() },
                onAnalyze = { navController.navigate(Destinations.POSTURE_ANALYSIS) },
            )
        }

        composable(Destinations.POSTURE_ANALYSIS) {
            PostureAnalysisScreen(
                onBack = { navController.popBackStack() },
                onOpenPhaseComparison = { navController.navigate(Destinations.PHASE_COMPARISON) },
                onOpenPoseCorrection = { frame ->
                    navController.navigate(Destinations.poseCorrection(frame))
                },
                onOpenArticle = { id -> navController.navigate(Destinations.article(id)) },
            )
        }

        composable(Destinations.PHASE_COMPARISON) {
            PhaseComparisonScreen(onBack = { navController.popBackStack() })
        }

        composable(
            Destinations.POSE_CORRECTION_ROUTE,
            arguments = listOf(
                navArgument(Destinations.POSE_CORRECTION_ARG) { type = NavType.IntType },
            ),
        ) { entry ->
            PoseCorrectionScreen(
                initialFrame = entry.arguments?.getInt(Destinations.POSE_CORRECTION_ARG) ?: 0,
                onBack = { navController.popBackStack() },
                onApplied = { navController.popBackStack() },
            )
        }

        composable(Destinations.FORM_HISTORY) {
            FormHistoryScreen(onBack = { navController.popBackStack() })
        }

        // ── Roulette ─────────────────────────────────────────────────────

        composable(Destinations.ROULETTE) {
            RouletteScreen(
                onBack = { navController.popBackStack() },
                onOpenScoredRound = { navController.navigate(Destinations.START_ROUND) },
                onOpenHistory = { navController.navigate(Destinations.ROULETTE_HISTORY) },
            )
        }

        composable(Destinations.START_ROUND) {
            StartRoundScreen(
                onBack = { navController.popBackStack() },
                onRoundStarted = {
                    navController.navigate(Destinations.PLAY_ROUND) {
                        popUpTo(Destinations.START_ROUND) { inclusive = true }
                    }
                },
            )
        }

        composable(Destinations.PLAY_ROUND) {
            PlayRoundScreen(
                onBack = { navController.popBackStack() },
                onOpenScorecard = { navController.navigate(Destinations.SCORECARD) },
                onRoundComplete = {
                    navController.navigate(Destinations.SCORECARD) {
                        popUpTo(Destinations.PLAY_ROUND) { inclusive = true }
                    }
                },
            )
        }

        composable(Destinations.SCORECARD) {
            ScorecardScreen(
                onBack = { navController.popBackStack() },
                // Finishing a round returns to the top rather than to the hole
                // that was just scored.
                onFinish = { navController.popBackStack(Destinations.HOME, inclusive = false) },
            )
        }

        composable(
            Destinations.SCORECARD_ROUTE,
            arguments = listOf(
                navArgument(Destinations.SCORECARD_ARG) { type = NavType.StringType },
            ),
        ) { entry ->
            ScorecardScreen(
                onBack = { navController.popBackStack() },
                onFinish = { navController.popBackStack() },
                savedRoundId = entry.arguments?.getString(Destinations.SCORECARD_ARG),
            )
        }

        composable(Destinations.ROULETTE_HISTORY) {
            RouletteHistoryScreen(onBack = { navController.popBackStack() })
        }

        // ── Knowledge base and settings ──────────────────────────────────

        composable(Destinations.KNOWLEDGE_BASE) {
            KnowledgeBaseScreen(
                onBack = { navController.popBackStack() },
                onOpenSearch = { navController.navigate(Destinations.AI_SEARCH) },
                onOpenCategory = { id -> navController.navigate(Destinations.category(id)) },
            )
        }

        composable(
            Destinations.CATEGORY_ROUTE,
            arguments = listOf(
                navArgument(Destinations.CATEGORY_ARG) { type = NavType.StringType },
            ),
        ) { entry ->
            CategoryScreen(
                categoryId = entry.arguments?.getString(Destinations.CATEGORY_ARG).orEmpty(),
                onBack = { navController.popBackStack() },
                onOpenArticle = { id -> navController.navigate(Destinations.article(id)) },
            )
        }

        composable(
            Destinations.ARTICLE_ROUTE,
            arguments = listOf(
                navArgument(Destinations.ARTICLE_ARG) { type = NavType.StringType },
            ),
        ) { entry ->
            ArticleDetailScreen(
                articleId = entry.arguments?.getString(Destinations.ARTICLE_ARG).orEmpty(),
                onBack = { navController.popBackStack() },
            )
        }

        composable(Destinations.AI_SEARCH) {
            AiSearchScreen(onBack = { navController.popBackStack() })
        }

        composable(Destinations.TRAINING_SETTINGS) {
            TrainingSettingsScreen(
                onBack = { navController.popBackStack() },
                onOpenPrivacyPolicy = { navController.navigate(Destinations.PRIVACY_POLICY) },
            )
        }

        composable(Destinations.PRIVACY_POLICY) {
            PrivacyPolicyScreen(onBack = { navController.popBackStack() })
        }
    }
}

/**
 * Show [content] with the clip being worked on, or leave the screen.
 *
 * The trimmer is only reachable once a video has been picked, but the process
 * can be killed while the camera or the picker is in front of the app. Coming
 * back to an empty trimmer would strand the user on a screen with nothing to
 * trim, so the screen backs out instead.
 */
@Composable
private fun WithVideo(
    videoPath: String?,
    onMissing: () -> Unit,
    content: @Composable (String) -> Unit,
) {
    if (videoPath == null) {
        LaunchedEffect(Unit) { onMissing() }
        return
    }
    content(videoPath)
}
