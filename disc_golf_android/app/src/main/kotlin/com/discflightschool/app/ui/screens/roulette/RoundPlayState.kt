package com.discflightschool.app.ui.screens.roulette

import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import com.discflightschool.core.model.ScoredRound
import com.discflightschool.core.model.ThrowRecord

/** App-scoped draft state so opening the scorecard cannot discard a live hole. */
class RoundPlayState {
    var roundId: String? = null
    val holeNumber = mutableStateOf(1)
    val currentThrows = mutableStateListOf<ThrowRecord>()
    val playerThrows = mutableStateMapOf<String, List<ThrowRecord>>()
    val playerStrokes = mutableStateMapOf<String, Int>()
    val completedPlayers = mutableStateListOf<String>()

    fun attach(round: ScoredRound) {
        if (roundId == round.id) return
        roundId = round.id
        val firstIncomplete = (1..round.coursePars.size).firstOrNull { hole ->
            round.playerNames.any { player ->
                round.scores.none { it.holeNumber == hole && it.playerName == player }
            }
        } ?: (round.coursePars.size + 1)
        holeNumber.value = firstIncomplete
        currentThrows.clear()
        playerThrows.clear()
        playerStrokes.clear()
        completedPlayers.clear()
        round.scores.filter { it.holeNumber == firstIncomplete }.forEach { score ->
            completedPlayers += score.playerName
            playerThrows[score.playerName] = score.throws
            playerStrokes[score.playerName] = score.strokes
        }
    }
}
