package com.discflightschool.core.data

import com.discflightschool.core.model.HoleScore
import com.discflightschool.core.model.ScoredRound
import java.time.Instant
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

/** Aggregate statistics across every completed round. */
data class ScoringStatistics(
    val totalRounds: Int,
    val playerScores: Map<String, List<Int>>,
    val playerRoundsPlayed: Map<String, Int>,
    val playerAverages: Map<String, Double>,
) {
    val isEmpty: Boolean get() = totalRounds == 0

    companion object {
        val EMPTY = ScoringStatistics(0, emptyMap(), emptyMap(), emptyMap())
    }
}

/**
 * The in-progress round and the archive of completed ones.
 *
 * A round is saved by id rather than appended. Completing a round, undoing the
 * last hole, and re-entering it re-triggers the save; appending would persist
 * the same round twice and double-count it in [statistics].
 */
class ScoringRepository(private val store: KeyValueStore) {

    private val _currentRound = MutableStateFlow<ScoredRound?>(null)
    val currentRound: StateFlow<ScoredRound?> = _currentRound.asStateFlow()

    private val _savedRounds = MutableStateFlow<List<ScoredRound>>(emptyList())
    val savedRounds: StateFlow<List<ScoredRound>> = _savedRounds.asStateFlow()

    private val _currentPlayer = MutableStateFlow<String?>(null)
    val currentPlayer: StateFlow<String?> = _currentPlayer.asStateFlow()

    init {
        _savedRounds.value = load()
    }

    fun startNewRound(
        playerNames: List<String>,
        customPars: List<Int>? = null,
        useWeighting: Boolean = true,
        now: Instant = Instant.now(),
    ) {
        _currentRound.value = ScoredRound(
            id = now.toEpochMilli().toString(),
            playerNames = playerNames,
            startedAt = now,
            coursePars = customPars ?: ScoredRound.defaultCourse(),
            scores = emptyList(),
            useWeighting = useWeighting,
        )
        _currentPlayer.value = playerNames.firstOrNull()
    }

    fun setCurrentPlayer(playerName: String) {
        _currentPlayer.value = playerName
    }

    fun addHoleScore(score: HoleScore, now: Instant = Instant.now()) {
        val round = _currentRound.value ?: return
        if (_currentPlayer.value == null) return

        // Re-entering a hole replaces its record rather than creating a
        // duplicate (for example after navigation restored round progress).
        val updatedScores = round.scores.filterNot {
            it.holeNumber == score.holeNumber && it.playerName == score.playerName
        } + score
        val willBeComplete = round.playerNames.all { player ->
            updatedScores.filter { it.playerName == player }.map { it.holeNumber }.distinct().size >=
                round.coursePars.size
        }

        val updated = round.copy(
            completedAt = if (willBeComplete) now else null,
            scores = updatedScores,
        )
        _currentRound.value = updated

        if (updated.isComplete) saveRound(updated)
    }

    fun undoLastScore() {
        val round = _currentRound.value ?: return
        if (round.scores.isEmpty()) return

        _currentRound.value = round.copy(
            // Reset completion, since a hole is being taken back.
            completedAt = null,
            scores = round.scores.dropLast(1),
        )
    }

    fun clearCurrentRound() {
        _currentRound.value = null
        _currentPlayer.value = null
    }

    fun deleteRound(id: String) {
        _savedRounds.value = _savedRounds.value.filterNot { it.id == id }
        persist()
    }

    fun roundsForPlayer(playerName: String): List<ScoredRound> =
        _savedRounds.value.filter { playerName in it.playerNames }

    fun roundById(id: String): ScoredRound? = _savedRounds.value.firstOrNull { it.id == id }

    fun statistics(): ScoringStatistics {
        val completed = _savedRounds.value.filter { it.isComplete }
        if (completed.isEmpty()) return ScoringStatistics.EMPTY

        val playerScores = LinkedHashMap<String, MutableList<Int>>()
        val playerRoundsPlayed = LinkedHashMap<String, Int>()

        for (round in completed) {
            for (player in round.playerNames) {
                playerScores.getOrPut(player) { mutableListOf() } += round.rawScoreToPar(player)
                playerRoundsPlayed[player] = (playerRoundsPlayed[player] ?: 0) + 1
            }
        }

        return ScoringStatistics(
            totalRounds = completed.size,
            playerScores = playerScores.mapValues { it.value.toList() },
            playerRoundsPlayed = playerRoundsPlayed,
            playerAverages = playerScores
                .filterValues { it.isNotEmpty() }
                .mapValues { (_, scores) -> scores.sum().toDouble() / scores.size },
        )
    }

    private fun saveRound(round: ScoredRound) {
        if (!round.isComplete) return
        val rounds = _savedRounds.value.toMutableList()
        val existing = rounds.indexOfFirst { it.id == round.id }
        if (existing == -1) rounds += round else rounds[existing] = round
        _savedRounds.value = rounds
        persist()
    }

    private fun persist() {
        store.putStringList(KEY, _savedRounds.value.map { it.toJson().toString() })
    }

    /**
     * Decode entry by entry: one corrupt record must not discard the rest of the
     * user's round history, and must not leave the repository unable to save.
     */
    private fun load(): List<ScoredRound> {
        val stored = store.getStringList(KEY) ?: return emptyList()
        val loaded = ArrayList<ScoredRound>(stored.size)
        for (entry in stored) {
            runCatching {
                ScoredRound.fromJson(json.parseToJsonElement(entry).jsonObject)
            }.onSuccess { loaded += it }
        }
        return loaded
    }

    companion object {
        const val KEY = "saved_rounds"
        private val json = Json { ignoreUnknownKeys = true; isLenient = true }

        /** Exposed so the app layer can share one parser configuration. */
        fun parseRound(raw: String): JsonObject = json.parseToJsonElement(raw).jsonObject
    }
}
