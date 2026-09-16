package com.discflightschool.core.model

import com.discflightschool.core.util.DateTimes
import java.time.Instant
import kotlin.random.Random
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Putting styles for when a player is in putting range. */
enum class PuttStyle {
    KNEELING, STRADDLE, TURBO, SPIN, PUSH, SPUSH;

    /** The name as persisted by earlier versions of the app (Dart enum names). */
    val jsonName: String
        get() = when (this) {
            KNEELING -> "kneeling"
            STRADDLE -> "straddle"
            TURBO -> "turbo"
            SPIN -> "spin"
            PUSH -> "push"
            SPUSH -> "spush"
        }

    companion object {
        fun fromJson(name: String): PuttStyle = entries.first { it.jsonName == name }
    }
}

enum class ShotType {
    HYZER, ANHYZER, FLAT, ROLLER, TOMAHAWK, THUMBER, GRENADE, SCOOBER;

    val jsonName: String
        get() = when (this) {
            HYZER -> "hyzer"
            ANHYZER -> "anhyzer"
            FLAT -> "flat"
            ROLLER -> "roller"
            TOMAHAWK -> "tomahawk"
            THUMBER -> "thumber"
            GRENADE -> "grenade"
            SCOOBER -> "scoober"
        }

    companion object {
        fun fromJson(name: String): ShotType = entries.first { it.jsonName == name }
    }
}

enum class PowerModifier {
    FULL_POWER, HALF_POWER, QUARTER_POWER, OVERHAND, STANDSTILL, RUN_UP, X_STEP;

    val jsonName: String
        get() = when (this) {
            FULL_POWER -> "fullPower"
            HALF_POWER -> "halfPower"
            QUARTER_POWER -> "quarterPower"
            OVERHAND -> "overhand"
            STANDSTILL -> "standstill"
            RUN_UP -> "runUp"
            X_STEP -> "xStep"
        }

    val displayName: String
        get() = when (this) {
            FULL_POWER -> "Full Power"
            HALF_POWER -> "Half Power"
            QUARTER_POWER -> "Quarter Power"
            OVERHAND -> "Overhand"
            STANDSTILL -> "Standstill"
            RUN_UP -> "Run Up"
            X_STEP -> "X Step"
        }

    companion object {
        fun fromJson(name: String): PowerModifier = entries.first { it.jsonName == name }
    }
}

enum class Hindrance {
    NONE, OFF_HAND, EYES_CLOSED, BACKWARDS, ONE_LEG, SITTING, KNEELING, SPIN_FIRST;

    val jsonName: String
        get() = when (this) {
            NONE -> "none"
            OFF_HAND -> "offHand"
            EYES_CLOSED -> "eyesClosed"
            BACKWARDS -> "backwards"
            ONE_LEG -> "oneLeg"
            SITTING -> "sitting"
            KNEELING -> "kneeling"
            SPIN_FIRST -> "spinFirst"
        }

    val displayName: String
        get() = when (this) {
            NONE -> "No Hindrance"
            OFF_HAND -> "Off Hand"
            EYES_CLOSED -> "Eyes Closed"
            BACKWARDS -> "Backwards"
            ONE_LEG -> "One Leg"
            SITTING -> "Sitting"
            KNEELING -> "Kneeling"
            SPIN_FIRST -> "Spin First"
        }

    companion object {
        fun fromJson(name: String): Hindrance = entries.first { it.jsonName == name }
    }
}

/** Disc lists for the different game modes. */
object DiscLists {
    /** The full disc list for casual roulette. */
    val all = listOf(
        "Putter", "Approach", "Utility", "Midrange", "Fairway Driver", "Distance Driver",
    )

    /** Speed 4 and under — used in scored rounds to encourage actual scoring. */
    val scoringRound = listOf("Putter", "Approach", "Midrange")

    /** Putters only — used when in putting range. */
    val putting = listOf("Putter")
}

/** One spun challenge: what to throw, how to throw it, and what to do to yourself first. */
data class RouletteResult(
    val shotType: ShotType,
    val discName: String? = null,
    val powerModifier: PowerModifier,
    val hindrance: Hindrance,
    /** Non-null when this is a putting challenge. */
    val puttStyle: PuttStyle? = null,
    val timestamp: Instant,
) {
    val isPutt: Boolean get() = puttStyle != null

    val difficultyMultiplier: Double
        get() {
            var multiplier = 1.0

            multiplier += when (shotType) {
                ShotType.FLAT, ShotType.HYZER -> 0.0
                ShotType.ANHYZER -> 0.2
                ShotType.ROLLER -> 0.3
                ShotType.SCOOBER, ShotType.TOMAHAWK, ShotType.THUMBER -> 0.5
                ShotType.GRENADE -> 0.7
            }

            multiplier += when (powerModifier) {
                PowerModifier.FULL_POWER, PowerModifier.RUN_UP, PowerModifier.X_STEP -> 0.0
                PowerModifier.HALF_POWER -> 0.1
                PowerModifier.STANDSTILL -> 0.2
                PowerModifier.QUARTER_POWER -> 0.3
                PowerModifier.OVERHAND -> 0.4
            }

            // Hindrance has the biggest impact.
            multiplier += when (hindrance) {
                Hindrance.NONE -> 0.0
                Hindrance.KNEELING, Hindrance.SITTING -> 0.3
                Hindrance.ONE_LEG -> 0.5
                Hindrance.SPIN_FIRST -> 0.7
                Hindrance.OFF_HAND -> 1.0
                Hindrance.BACKWARDS -> 1.2
                Hindrance.EYES_CLOSED -> 1.5
            }

            puttStyle?.let {
                multiplier += when (it) {
                    PuttStyle.PUSH -> 0.0
                    PuttStyle.SPUSH -> 0.1
                    PuttStyle.SPIN -> 0.2
                    PuttStyle.STRADDLE -> 0.3
                    PuttStyle.KNEELING -> 0.5
                    PuttStyle.TURBO -> 0.7
                }
            }

            return multiplier
        }

    val shotTypeDescription: String
        get() = when (shotType) {
            ShotType.HYZER -> "Hyzer - Outside edge down"
            ShotType.ANHYZER -> "Anhyzer - Outside edge up"
            ShotType.FLAT -> "Flat - Level release"
            ShotType.ROLLER -> "Roller - Ground roll shot"
            ShotType.TOMAHAWK -> "Tomahawk - Overhead hyzer"
            ShotType.THUMBER -> "Thumber - Overhead anhyzer"
            ShotType.GRENADE -> "Grenade - Vertical release"
            ShotType.SCOOBER -> "Scoober - Upside down"
        }

    val puttStyleDescription: String
        get() = when (puttStyle) {
            null -> ""
            PuttStyle.PUSH -> "Push Putt - Wrist stays firm"
            PuttStyle.SPUSH -> "Spush Putt - Spin + push hybrid"
            PuttStyle.SPIN -> "Spin Putt - Wrist flick"
            PuttStyle.STRADDLE -> "Straddle Putt - Feet parallel to basket"
            PuttStyle.KNEELING -> "Kneeling Putt - One knee down"
            PuttStyle.TURBO -> "Turbo Putt - Overhead grip"
        }

    fun toJson(): JsonObject = buildJsonObject {
        put("shotType", JsonPrimitive(shotType.jsonName))
        put("discName", discName?.let { JsonPrimitive(it) } ?: JsonNull)
        put("powerModifier", JsonPrimitive(powerModifier.jsonName))
        put("hindrance", JsonPrimitive(hindrance.jsonName))
        put("puttStyle", puttStyle?.let { JsonPrimitive(it.jsonName) } ?: JsonNull)
        put("timestamp", JsonPrimitive(DateTimes.format(timestamp)))
    }

    companion object {
        /**
         * Power modifiers that are physically impossible with a given hindrance.
         * Hindrance is picked first; incompatible powers are removed before sampling.
         */
        private val incompatiblePower: Map<Hindrance, List<PowerModifier>> = mapOf(
            // You cannot run or x-step from the ground.
            Hindrance.KNEELING to listOf(PowerModifier.RUN_UP, PowerModifier.X_STEP),
            Hindrance.SITTING to listOf(PowerModifier.RUN_UP, PowerModifier.X_STEP),
            // You cannot plant both feet for an x-step, or run, on one leg.
            Hindrance.ONE_LEG to listOf(PowerModifier.RUN_UP, PowerModifier.X_STEP),
        )

        fun generate(
            availableDiscs: List<String>,
            random: Random = Random.Default,
            now: Instant = Instant.now(),
        ): RouletteResult {
            val hindrance = Hindrance.entries[random.nextInt(Hindrance.entries.size)]
            val blocked = incompatiblePower[hindrance].orEmpty()
            val validPowers = PowerModifier.entries.filterNot { it in blocked }

            return RouletteResult(
                shotType = ShotType.entries[random.nextInt(ShotType.entries.size)],
                discName = availableDiscs.getOrNull(
                    if (availableDiscs.isEmpty()) -1 else random.nextInt(availableDiscs.size),
                ),
                powerModifier = validPowers[random.nextInt(validPowers.size)],
                hindrance = hindrance,
                timestamp = now,
            )
        }

        /** Generate a putting-specific challenge. */
        fun generatePutt(
            availableDiscs: List<String>,
            random: Random = Random.Default,
            now: Instant = Instant.now(),
        ): RouletteResult = RouletteResult(
            // Putts are always flat, always standstill, and the hindrance is
            // replaced by the putt style.
            shotType = ShotType.FLAT,
            discName = availableDiscs.getOrNull(
                if (availableDiscs.isEmpty()) -1 else random.nextInt(availableDiscs.size),
            ),
            powerModifier = PowerModifier.STANDSTILL,
            hindrance = Hindrance.NONE,
            puttStyle = PuttStyle.entries[random.nextInt(PuttStyle.entries.size)],
            timestamp = now,
        )

        fun fromJson(json: JsonObject): RouletteResult = RouletteResult(
            shotType = ShotType.fromJson(json.getValue("shotType").jsonPrimitive.content),
            discName = json["discName"]?.takeIf { it !is JsonNull }?.jsonPrimitive?.content,
            powerModifier = PowerModifier.fromJson(
                json.getValue("powerModifier").jsonPrimitive.content,
            ),
            hindrance = Hindrance.fromJson(json.getValue("hindrance").jsonPrimitive.content),
            puttStyle = json["puttStyle"]?.takeIf { it !is JsonNull }
                ?.jsonPrimitive?.content?.let { PuttStyle.fromJson(it) },
            timestamp = DateTimes.parse(json.getValue("timestamp").jsonPrimitive.content),
        )
    }
}

/** A casual (unscored) session of spins shared by a group. */
data class GameSession(
    val id: String,
    val players: List<String>,
    val results: List<RouletteResult>,
    val startedAt: Instant,
    val endedAt: Instant? = null,
) {
    fun toJson(): JsonObject = buildJsonObject {
        put("id", JsonPrimitive(id))
        put("players", JsonArray(players.map { JsonPrimitive(it) }))
        put("results", JsonArray(results.map { it.toJson() }))
        put("startedAt", JsonPrimitive(DateTimes.format(startedAt)))
        put("endedAt", endedAt?.let { JsonPrimitive(DateTimes.format(it)) } ?: JsonNull)
    }

    companion object {
        fun fromJson(json: JsonObject): GameSession = GameSession(
            id = json.getValue("id").jsonPrimitive.content,
            players = json.getValue("players").jsonArray.map { it.jsonPrimitive.content },
            results = json.getValue("results").jsonArray.map {
                RouletteResult.fromJson(it.jsonObject)
            },
            startedAt = DateTimes.parse(json.getValue("startedAt").jsonPrimitive.content),
            endedAt = json["endedAt"]?.takeIf { it !is JsonNull }
                ?.jsonPrimitive?.content?.let { DateTimes.parse(it) },
        )
    }
}
