package com.discflightschool.core.data

import com.discflightschool.core.model.RouletteResult
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/** Disc Roulette spins, newest first, capped at [MAX_ENTRIES]. */
class RouletteHistoryRepository(private val store: KeyValueStore) {

    private val _history = MutableStateFlow<List<RouletteResult>>(emptyList())
    val history: StateFlow<List<RouletteResult>> = _history.asStateFlow()

    init {
        _history.value = load()
    }

    fun addResult(result: RouletteResult) {
        _history.value = (listOf(result) + _history.value).take(MAX_ENTRIES)
        persist()
    }

    fun clearHistory() {
        _history.value = emptyList()
        persist()
    }

    private fun persist() {
        store.putString(KEY, JsonArray(_history.value.map { it.toJson() }).toString())
    }

    private fun load(): List<RouletteResult> {
        val raw = store.getString(KEY) ?: return emptyList()
        val array = runCatching { json.parseToJsonElement(raw).jsonArray }.getOrNull()
            ?: return emptyList()
        return array.mapNotNull { element ->
            runCatching { RouletteResult.fromJson(element.jsonObject) }.getOrNull()
        }
    }

    companion object {
        const val KEY = "roulette_spin_history"
        const val MAX_ENTRIES = 200
        private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    }
}
