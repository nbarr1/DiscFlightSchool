package com.discflightschool.core.model

import com.discflightschool.core.util.DateTimes
import java.time.Instant
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** One throw within a hole, including the challenge spun for it. */
data class ThrowRecord(
    val throwNumber: Int,
    val challenge: RouletteResult,
    val isPutt: Boolean = false,
) {
    val multiplier: Double get() = challenge.difficultyMultiplier

    fun toJson(): JsonObject = buildJsonObject {
        put("throwNumber", JsonPrimitive(throwNumber))
        put("challenge", challenge.toJson())
        put("isPutt", JsonPrimitive(isPutt))
    }

    companion object {
        fun fromJson(json: JsonObject): ThrowRecord = ThrowRecord(
            throwNumber = json.getValue("throwNumber").jsonPrimitive.int,
            challenge = RouletteResult.fromJson(json.getValue("challenge").jsonObject),
            isPutt = runCatching { json["isPutt"]?.jsonPrimitive?.boolean }.getOrNull() ?: false,
        )
    }
}

/** One player's score on one hole. */
data class HoleScore(
    val holeNumber: Int,
    val par: Int,
    val strokes: Int,
    val throws: List<ThrowRecord>,
    val playerName: String,
) {
    val rawScore: Int get() = strokes - par

    /** The average difficulty multiplier across every throw on this hole. */
    val averageMultiplier: Double
        get() = if (throws.isEmpty()) 1.0 else throws.sumOf { it.multiplier } / throws.size

    val weightedScore: Double get() = rawScore * averageMultiplier

    fun toJson(): JsonObject = buildJsonObject {
        put("holeNumber", JsonPrimitive(holeNumber))
        put("par", JsonPrimitive(par))
        put("strokes", JsonPrimitive(strokes))
        put("throws", JsonArray(throws.map { it.toJson() }))
        put("playerName", JsonPrimitive(playerName))
    }

    companion object {
        fun fromJson(json: JsonObject): HoleScore {
            // Support the legacy format, which carried a single `challenge`.
            if (json.containsKey("challenge") && !json.containsKey("throws")) {
                val challenge = RouletteResult.fromJson(json.getValue("challenge").jsonObject)
                return HoleScore(
                    holeNumber = json.getValue("holeNumber").jsonPrimitive.int,
                    par = json.getValue("par").jsonPrimitive.int,
                    strokes = json.getValue("strokes").jsonPrimitive.int,
                    throws = listOf(ThrowRecord(throwNumber = 1, challenge = challenge)),
                    playerName = json.getValue("playerName").jsonPrimitive.content,
                )
            }

            return HoleScore(
                holeNumber = json.getValue("holeNumber").jsonPrimitive.int,
                par = json.getValue("par").jsonPrimitive.int,
                strokes = json.getValue("strokes").jsonPrimitive.int,
                throws = json.getValue("throws").jsonArray.map { ThrowRecord.fromJson(it.jsonObject) },
                playerName = json.getValue("playerName").jsonPrimitive.content,
            )
        }
    }
}

/** A full scored round for one or more players. */
data class ScoredRound(
    val id: String,
    val playerNames: List<String>,
    val startedAt: Instant,
    val completedAt: Instant? = null,
    val coursePars: List<Int>,
    val scores: List<HoleScore>,
    val useWeighting: Boolean = true,
) {
    fun totalRawStrokes(playerName: String): Int =
        scores.filter { it.playerName == playerName }.sumOf { it.strokes }

    val totalPar: Int get() = coursePars.sum()

    fun rawScoreToPar(playerName: String): Int = totalRawStrokes(playerName) - totalPar

    fun totalWeightedScore(playerName: String): Double =
        scores.filter { it.playerName == playerName }.sumOf { it.weightedScore }

    val isComplete: Boolean
        get() = playerNames.all { player ->
            scores.count { it.playerName == player } >= coursePars.size
        }

    fun currentHole(playerName: String): Int =
        scores.count { it.playerName == playerName } + 1

    fun toJson(): JsonObject = buildJsonObject {
        put("id", JsonPrimitive(id))
        put("playerNames", JsonArray(playerNames.map { JsonPrimitive(it) }))
        put("startedAt", JsonPrimitive(DateTimes.format(startedAt)))
        put("completedAt", completedAt?.let { JsonPrimitive(DateTimes.format(it)) } ?: JsonNull)
        put("coursePars", JsonArray(coursePars.map { JsonPrimitive(it) }))
        put("scores", JsonArray(scores.map { it.toJson() }))
        put("useWeighting", JsonPrimitive(useWeighting))
    }

    companion object {
        fun defaultCourse(holes: Int = 18, defaultPar: Int = 3): List<Int> =
            List(holes) { defaultPar }

        fun fromJson(json: JsonObject): ScoredRound = ScoredRound(
            id = json.getValue("id").jsonPrimitive.content,
            playerNames = json.getValue("playerNames").jsonArray.map { it.jsonPrimitive.content },
            startedAt = DateTimes.parse(json.getValue("startedAt").jsonPrimitive.content),
            completedAt = json["completedAt"]?.takeIf { it !is JsonNull }
                ?.jsonPrimitive?.content?.let { DateTimes.parse(it) },
            coursePars = json.getValue("coursePars").jsonArray.map { it.jsonPrimitive.int },
            scores = json.getValue("scores").jsonArray.map { HoleScore.fromJson(it.jsonObject) },
            useWeighting = runCatching { json["useWeighting"]?.jsonPrimitive?.boolean }
                .getOrNull() ?: true,
        )
    }
}
