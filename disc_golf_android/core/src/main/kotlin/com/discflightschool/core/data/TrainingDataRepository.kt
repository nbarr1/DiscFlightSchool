package com.discflightschool.core.data

import com.discflightschool.core.model.TrainingSample
import com.discflightschool.core.net.ServerUris
import java.net.URI
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/** Where the sample manifest is read from and written to. */
interface ManifestStore {
    fun read(): String?
    fun write(content: String)
}

/** An in-memory [ManifestStore] for tests. */
class InMemoryManifestStore(private var content: String? = null) : ManifestStore {
    override fun read(): String? = content

    override fun write(content: String) {
        this.content = content
    }
}

/**
 * Opt-in state, server configuration, and the local sample manifest for
 * training data collection.
 *
 * Uploading and model downloads live in the platform layer; what belongs here is
 * the part that decides *whether* a request may be made at all, and what
 * happens to a stored credential when the user points the app somewhere new.
 */
class TrainingDataRepository(
    private val store: KeyValueStore,
    private val secrets: SecretStore,
    private val manifestStore: ManifestStore,
) {

    private val _isOptedIn = MutableStateFlow(store.getBoolean(OPT_IN_KEY) ?: false)
    val isOptedIn: StateFlow<Boolean> = _isOptedIn.asStateFlow()

    private val _serverUrl = MutableStateFlow(
        store.getString(SERVER_URL_KEY)?.takeIf { it.isNotEmpty() } ?: DEFAULT_SERVER_URL,
    )
    val serverUrl: StateFlow<String> = _serverUrl.asStateFlow()

    private val _apiKey = MutableStateFlow(
        runCatching { secrets.read(API_KEY_KEY) }.getOrNull().orEmpty(),
    )
    val hasApiKey: Boolean get() = _apiKey.value.isNotEmpty()
    val apiKey: String get() = _apiKey.value

    private val _samples = MutableStateFlow(loadManifest())
    val samples: StateFlow<List<TrainingSample>> = _samples.asStateFlow()

    val totalSamples: Int get() = _samples.value.size
    val uploadedSamples: Int get() = _samples.value.count { it.uploaded }
    val pendingSamples: Int get() = _samples.value.count { !it.uploaded }

    fun setOptIn(value: Boolean) {
        _isOptedIn.value = value
        store.putBoolean(OPT_IN_KEY, value)
    }

    /**
     * Set the server URL for uploads and model updates.
     *
     * Changing the server origin clears the stored API key: the key was issued
     * by the previous server, and silently forwarding it to a new host would
     * leak the user's credential to whatever they just pointed the app at.
     */
    fun setServerUrl(url: String) {
        val previousOrigin = ServerUris.originOf(_serverUrl.value)
        val nextOrigin = ServerUris.originOf(url)

        _serverUrl.value = url
        store.putString(SERVER_URL_KEY, url)

        if (previousOrigin != nextOrigin && _apiKey.value.isNotEmpty()) {
            setApiKey("")
        }
    }

    /** Store the private training API key used for uploads and admin operations. */
    fun setApiKey(key: String) {
        val trimmed = key.trim()
        _apiKey.value = trimmed
        runCatching {
            if (trimmed.isEmpty()) secrets.delete(API_KEY_KEY) else secrets.write(API_KEY_KEY, trimmed)
        }
    }

    fun clearApiKey() = setApiKey("")

    /** The endpoint for [path], or null when the configured server is not usable. */
    fun endpoint(path: String): URI? = ServerUris.endpoint(_serverUrl.value, path)

    fun addSamples(samples: List<TrainingSample>) {
        if (samples.isEmpty()) return
        _samples.value = _samples.value + samples
        saveManifest()
    }

    fun markUploaded(ids: Set<String>) {
        if (ids.isEmpty()) return
        _samples.value = _samples.value.map {
            if (it.id in ids) it.copy(uploaded = true) else it
        }
        saveManifest()
    }

    fun clearSamples() {
        _samples.value = emptyList()
        saveManifest()
    }

    var modelVersion: String
        get() = store.getString(MODEL_VERSION_KEY) ?: BUNDLED_MODEL_VERSION
        set(value) = store.putString(MODEL_VERSION_KEY, value)

    private fun saveManifest() {
        manifestStore.write(JsonArray(_samples.value.map { it.toJson() }).toString())
    }

    private fun loadManifest(): List<TrainingSample> {
        val content = runCatching { manifestStore.read() }.getOrNull() ?: return emptyList()
        val array = runCatching { json.parseToJsonElement(content).jsonArray }.getOrNull()
            ?: return emptyList()
        return array.mapNotNull { element ->
            runCatching { TrainingSample.fromJson(element.jsonObject) }.getOrNull()
        }
    }

    companion object {
        const val OPT_IN_KEY = "training_opt_in"
        const val SERVER_URL_KEY = "training_server_url"
        const val API_KEY_KEY = "training_api_key"
        const val MODEL_VERSION_KEY = "disc_model_version"
        const val DEFAULT_SERVER_URL = "https://discflightschool.onrender.com"
        const val BUNDLED_MODEL_VERSION = "bundled-1.0.0"

        /** The normalized bounding-box size used when a keyframe carries none. */
        const val DEFAULT_BOX_SIZE = 0.03

        /** The crop region saved alongside each full frame, in pixels. */
        const val CROP_PIXELS = 64

        private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    }
}

/** A keyframe marked by the user, ready to be turned into a labelled sample. */
data class KeyframeData(
    val frameIndex: Int,
    /** Normalized 0-1. */
    val x: Double,
    /** Normalized 0-1. */
    val y: Double,
    /** Normalized 0-1, or null to use the default box size. */
    val boxWidth: Double? = null,
    val boxHeight: Double? = null,
)
