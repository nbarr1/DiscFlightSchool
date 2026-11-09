package com.discflightschool.core.data

import com.discflightschool.core.model.FormSessionRecord
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject

/** Saved form analysis sessions, newest first. */
class FormHistoryRepository(private val store: KeyValueStore) {

    private val _sessions = MutableStateFlow<List<FormSessionRecord>>(emptyList())
    val sessions: StateFlow<List<FormSessionRecord>> = _sessions.asStateFlow()

    init {
        _sessions.value = load()
    }

    fun saveSession(record: FormSessionRecord) {
        _sessions.value = (listOf(record) + _sessions.value).take(MAX_RECORDS)
        persist()
    }

    /**
     * Record, change, or clear (with null) the distance the player reported
     * for a saved session. Returns false when no session has that [id].
     *
     * A distance that isn't a positive, finite number is stored as null.
     */
    fun setDistance(id: String, distanceFeet: Double?): Boolean {
        val clean = distanceFeet?.takeIf { it.isFinite() && it > 0.0 }
        var found = false
        _sessions.value = _sessions.value.map { record ->
            if (record.id == id) {
                found = true
                record.copy(distanceFeet = clean)
            } else {
                record
            }
        }
        if (found) persist()
        return found
    }

    fun clearHistory() {
        _sessions.value = emptyList()
        store.remove(KEY)
    }

    /**
     * The last [n] sessions for a throw type, oldest first, for trend charting.
     */
    fun trend(throwType: String, n: Int = 10): List<FormSessionRecord> =
        _sessions.value.filter { it.throwType == throwType }.take(n).reversed()

    private fun persist() {
        store.putStringList(KEY, _sessions.value.map { it.toJson().toString() })
    }

    private fun load(): List<FormSessionRecord> {
        val stored = store.getStringList(KEY) ?: return emptyList()
        return stored.mapNotNull { entry ->
            runCatching {
                FormSessionRecord.fromJson(json.parseToJsonElement(entry).jsonObject)
            }.getOrNull()
        }
    }

    companion object {
        const val KEY = "form_session_history"
        const val MAX_RECORDS = 50
        private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    }
}
