package com.discflightschool.app

import android.content.Context
import com.discflightschool.app.data.AiSearchClient
import com.discflightschool.app.data.AssetContent
import com.discflightschool.app.data.EncryptedSecretStore
import com.discflightschool.app.data.DiscDetectionClient
import com.discflightschool.app.data.DiscFlightClient
import com.discflightschool.app.data.FileManifestStore
import com.discflightschool.app.data.FlightGalleryRepository
import com.discflightschool.app.data.KnowledgeBaseRepository
import com.discflightschool.app.data.ProBaselineRepository
import com.discflightschool.app.data.SharedPreferencesStore
import com.discflightschool.app.data.TrainingDataCollector
import com.discflightschool.app.data.VideoLibrary
import com.discflightschool.app.data.migrateFlutterPreferences
import com.discflightschool.app.detection.DiscDetector
import com.discflightschool.app.pose.PostureAnalyzer
import com.discflightschool.app.ui.WorkbenchState
import com.discflightschool.app.ui.screens.roulette.RoundPlayState
import com.discflightschool.app.video.FrameExtractor
import com.discflightschool.core.data.AppPreferences
import com.discflightschool.core.data.DetectionSettings
import com.discflightschool.core.data.FormHistoryRepository
import com.discflightschool.core.data.RouletteHistoryRepository
import com.discflightschool.core.data.ScoringRepository
import com.discflightschool.core.data.TrainingDataRepository
import java.io.File

/**
 * The app's long-lived objects, built once and shared by every screen.
 *
 * Deliberately a plain container rather than a dependency-injection framework:
 * there are a dozen singletons and one lifetime, and a graph that can be read
 * top to bottom is worth more here than the wiring a framework would save.
 *
 * The detector and the pose analyzer hold native resources, so they live here
 * rather than in a screen's ViewModel — a tracker that disposed the shared
 * interpreter would break detection for the rest of the session.
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
    private val secretStore = EncryptedSecretStore(appContext)

    /** The root of everything the app collects for detector training. */
    val trainingDataDir: File = File(appContext.filesDir, "training_data")

    val appPreferences = AppPreferences(preferencesStore)
    val detectionSettings = DetectionSettings(preferencesStore)

    val scoringRepository = ScoringRepository(preferencesStore)
    val formHistoryRepository = FormHistoryRepository(preferencesStore)
    val rouletteHistoryRepository = RouletteHistoryRepository(preferencesStore)

    val trainingDataRepository = TrainingDataRepository(
        store = preferencesStore,
        secrets = secretStore,
        manifestStore = FileManifestStore(File(trainingDataDir, "manifest.json")),
    )

    private val assets = AssetContent(appContext)

    val knowledgeBaseRepository = KnowledgeBaseRepository(assets, secretStore)
    val proBaselineRepository = ProBaselineRepository(assets)

    val frameExtractor = FrameExtractor()
    val videoLibrary = VideoLibrary(appContext)
    val flightGalleryRepository = FlightGalleryRepository(
        context = appContext,
        store = preferencesStore,
        frameExtractor = frameExtractor,
    )

    val discDetector = DiscDetector(
        context = appContext,
        settings = detectionSettings,
        frameExtractor = frameExtractor,
        trainingDataDir = trainingDataDir,
    )

    val postureAnalyzer = PostureAnalyzer(frameExtractor)

    val trainingDataCollector = TrainingDataCollector(
        repository = trainingDataRepository,
        frameExtractor = frameExtractor,
        dataDir = trainingDataDir,
    )

    val aiSearchClient = AiSearchClient()
    val discFlightClient = DiscFlightClient(
        File(appContext.cacheDir, "disc_flight_results"),
        trainingDataRepository,
    )
    val discDetectionClient = DiscDetectionClient(trainingDataRepository)

    /** The clip being worked on, shared across the screens of one flow. */
    val workbench = WorkbenchState()
    val roundPlayState = RoundPlayState()

    /** Releases the native resources held for the life of the process. */
    fun shutdown() {
        discDetector.close()
        postureAnalyzer.close()
    }
}
