package com.discflightschool.app.data

import android.content.Context
import android.util.Log
import com.discflightschool.core.baseline.ProBaselineDatabase
import com.discflightschool.core.data.SecretStore
import com.discflightschool.core.knowledge.KnowledgeSearch
import com.discflightschool.core.model.KBArticle
import com.discflightschool.core.model.KBCategory
import com.discflightschool.core.model.KBStudy
import com.discflightschool.core.model.KnowledgeBaseContent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

/** Reads the JSON bundled in the APK. */
class AssetContent(private val context: Context) {

    suspend fun readText(path: String): String = withContext(Dispatchers.IO) {
        context.assets.open(path).bufferedReader().use { it.readText() }
    }

    companion object {
        const val KNOWLEDGE_BASE = "data/knowledge_base.json"
        const val PRO_BASELINE = "data/pro_baseline_db.json"
        const val DETECTOR_MODEL = "models/disc_detector.tflite"
    }
}

/**
 * The bundled research library, and the API key AI search needs.
 *
 * Content is parsed once on first use; the key is read from encrypted storage
 * and never from ordinary preferences.
 */
class KnowledgeBaseRepository(
    private val assets: AssetContent,
    private val secrets: SecretStore,
) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val loadMutex = Mutex()

    private val _content = MutableStateFlow(KnowledgeBaseContent())
    val content: StateFlow<KnowledgeBaseContent> = _content.asStateFlow()

    private val _isLoaded = MutableStateFlow(false)
    val isLoaded: StateFlow<Boolean> = _isLoaded.asStateFlow()

    private val _hasApiKey = MutableStateFlow(
        runCatching { secrets.read(API_KEY) }.getOrNull().orEmpty().isNotEmpty(),
    )
    val hasApiKey: StateFlow<Boolean> = _hasApiKey.asStateFlow()

    val studies: List<KBStudy> get() = _content.value.studies
    val articles: List<KBArticle> get() = _content.value.articles
    val categories: List<KBCategory> get() = _content.value.categories

    suspend fun load() {
        if (_isLoaded.value) return
        loadMutex.withLock {
            if (_isLoaded.value) return
            runCatching {
                json.decodeFromString(
                    KnowledgeBaseContent.serializer(),
                    assets.readText(AssetContent.KNOWLEDGE_BASE),
                )
            }.onSuccess {
                _content.value = it
                _isLoaded.value = true
            }.onFailure {
                Log.e(TAG, "Could not read the bundled knowledge base", it)
            }
        }
    }

    fun articles(category: String? = null, type: String? = null): List<KBArticle> =
        articles.filter { article ->
            (category == null || article.category == category) &&
                (type == null || article.type == type)
        }

    fun articleCount(categoryId: String): Int = articles.count { it.category == categoryId }

    /** How many distinct studies the articles in a category cite. */
    fun studyCount(categoryId: String): Int = articles
        .filter { it.category == categoryId }
        .flatMap { it.sourceIds }
        .toSet()
        .size

    fun randomTip(): KBArticle? = articles.filter { it.isTip }.randomOrNull()

    fun study(id: String): KBStudy? = studies.firstOrNull { it.id == id }

    fun searchLocal(query: String): String =
        KnowledgeSearch.searchLocal(query, articles, studies)

    fun apiKey(): String = runCatching { secrets.read(API_KEY) }.getOrNull().orEmpty()

    fun setApiKey(key: String) {
        val trimmed = key.trim()
        runCatching {
            if (trimmed.isEmpty()) secrets.delete(API_KEY) else secrets.write(API_KEY, trimmed)
        }.onFailure { Log.w(TAG, "Could not update the stored Anthropic API key", it) }
        _hasApiKey.value = trimmed.isNotEmpty()
    }

    fun clearApiKey() = setApiKey("")

    private companion object {
        const val TAG = "KnowledgeBaseRepository"
        const val API_KEY = "anthropic_api_key"
    }
}

/** The bundled pro baseline database, parsed on first use. */
class ProBaselineRepository(private val assets: AssetContent) {

    private val loadMutex = Mutex()
    private var database: ProBaselineDatabase? = null

    suspend fun database(): ProBaselineDatabase? {
        database?.let { return it }
        return loadMutex.withLock {
            database ?: runCatching {
                ProBaselineDatabase.parse(assets.readText(AssetContent.PRO_BASELINE))
            }.onFailure {
                Log.e(TAG, "Could not read the bundled pro baseline database", it)
            }.getOrNull()?.also { database = it }
        }
    }

    private companion object {
        const val TAG = "ProBaselineRepository"
    }
}
