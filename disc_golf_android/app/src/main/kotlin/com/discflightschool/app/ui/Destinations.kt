package com.discflightschool.app.ui

import android.net.Uri

/**
 * Every screen in the app, and the arguments needed to reach it.
 *
 * Only identifiers and small values travel through the back stack. A pose
 * analysis or a full flight path is held in [WorkbenchState] instead: those
 * objects are large, are edited in place across several screens, and would not
 * survive a route encode/decode round trip intact.
 */
object Destinations {
    const val ONBOARDING = "onboarding"
    const val HOME = "home"

    const val FLIGHT_TRACKER = "flight_tracker"
    const val FLIGHT_TRIM = "flight_trim"
    const val FLIGHT_PLAYER = "flight_player"
    const val VIDEO_GALLERY = "video_gallery"

    const val FORM_COACH = "form_coach"
    const val FORM_TRIM = "form_trim"
    const val POSTURE_ANALYSIS = "posture_analysis"
    const val PHASE_FRAME_SELECTOR = "phase_frame_selector"
    const val PHASE_COMPARISON = "phase_comparison"
    const val FORM_HISTORY = "form_history"

    const val ROULETTE = "roulette"
    const val START_ROUND = "start_round"
    const val PLAY_ROUND = "play_round"
    const val SCORECARD = "scorecard"
    const val ROULETTE_HISTORY = "roulette_history"

    const val KNOWLEDGE_BASE = "knowledge_base"
    const val AI_SEARCH = "ai_search"
    const val TRAINING_SETTINGS = "training_settings"
    const val PRIVACY_POLICY = "privacy_policy"

    /** Correcting the pose on one frame, by its index in the analysis. */
    fun poseCorrection(frameIndex: Int) = "pose_correction/$frameIndex"
    const val POSE_CORRECTION_ROUTE = "pose_correction/{frameIndex}"
    const val POSE_CORRECTION_ARG = "frameIndex"

    /** A knowledge base category, by id. */
    fun category(id: String) = "kb_category/${Uri.encode(id)}"
    const val CATEGORY_ROUTE = "kb_category/{categoryId}"
    const val CATEGORY_ARG = "categoryId"

    /** One article, by id. */
    fun article(id: String) = "kb_article/${Uri.encode(id)}"
    const val ARTICLE_ROUTE = "kb_article/{articleId}"
    const val ARTICLE_ARG = "articleId"

    /** A saved scorecard, by round id. */
    fun scorecard(roundId: String) = "scorecard/${Uri.encode(roundId)}"
    const val SCORECARD_ROUTE = "scorecard/{roundId}"
    const val SCORECARD_ARG = "roundId"
}
