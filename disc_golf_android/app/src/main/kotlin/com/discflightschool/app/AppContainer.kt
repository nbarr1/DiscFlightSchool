package com.discflightschool.app

import android.content.Context
import com.discflightschool.app.data.AssetContent
import com.discflightschool.app.data.EncryptedSecretStore
import com.discflightschool.app.data.KnowledgeBaseRepository
import com.discflightschool.app.data.ProBaselineRepository
import com.discflightschool.app.data.SharedPreferencesStore
import com.discflightschool.app.data.VideoLibrary
import com.discflightschool.app.data.migrateFlutterPreferences
import com.discflightschool.app.pose.PostureAnalyzer
import com.discflightschool.app.ui.WorkbenchState
import com.discflightschool.app.ui.screens.roulette.RoundPlayState
import com.discflightschool.app.video.FrameExtractor
import com.discflightschool.core.data.AppPreferences
import com.discflightschool.core.data.FormHistoryRepository
import com.discflightschool.core.data.RouletteHistoryRepository
import com.discflightschool.core.data.ScoringRepository

/**
 * The app's long-lived objects, built once and shared by every screen.
 *
 * Deliberately a plain container rather than a dependency-injection framework:
 * there are a dozen singletons and one lifetime, and a graph that can be read
 * top to bottom is worth more here than the wiring a framework would save.
 *
 * The pose analyzer holds native resources, so it lives here rather than in a
 * screen's ViewModel — a screen that disposed the shared detector would break
 * pose detection for the rest of the session.
 */
class AppContainer(context: Context) {

    private val appContext = context.applicationContext

    private val preferencesStore = SharedPreferencesStore(
        appContext.getSharedPreferences("disc_flight_school", Context.MODE_PRIVATE),
    ).also {
        // Before anything reads it: an install upgrading from the Flutter
        // client keeps its data directory, and this is what makes the data in
        // it visible to the repositories below.
        migrateFlutterPreferences(appContext, it)
    }
    private val secretStore = EncryptedSecretStore(appContext).also {
        // Earlier versions let the user store an Anthropic API key for AI
        // search. That feature is gone, so nothing reads the key any more;
        // removing it keeps a credential from lingering on the device unused.
        it.delete(LEGACY_ANTHROPIC_API_KEY)
        // The same for the removed disc-training uploads' server key.
        it.delete(LEGACY_TRAINING_API_KEY)
    }

    val appPreferences = AppPreferences(preferencesStore)

    val scoringRepository = ScoringRepository(preferencesStore)
    val formHistoryRepository = FormHistoryRepository(preferencesStore)
    val rouletteHistoryRepository = RouletteHistoryRepository(preferencesStore)

    private val assets = AssetContent(appContext)

    val knowledgeBaseRepository = KnowledgeBaseRepository(assets)
    val proBaselineRepository = ProBaselineRepository(assets)

    val frameExtractor = FrameExtractor()
    val videoLibrary = VideoLibrary(appContext)

    val postureAnalyzer = PostureAnalyzer(frameExtractor)

    /** The clip being worked on, shared across the screens of one flow. */
    val workbench = WorkbenchState()
    val roundPlayState = RoundPlayState()

    /** Releases the native resources held for the life of the process. */
    fun shutdown() {
        postureAnalyzer.close()
    }

    private companion object {
        /** Where the removed AI search feature kept its key in encrypted storage. */
        const val LEGACY_ANTHROPIC_API_KEY = "anthropic_api_key"

        /** Where the removed training-upload feature kept its server key. */
        const val LEGACY_TRAINING_API_KEY = "training_api_key"
    }
}
