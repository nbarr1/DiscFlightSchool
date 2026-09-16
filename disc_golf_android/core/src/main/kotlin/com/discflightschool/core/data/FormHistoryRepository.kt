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
