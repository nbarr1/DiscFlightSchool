package com.discflightschool.core.baseline

import com.discflightschool.core.model.ThrowTypes
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Reads `pro_baseline_db.json` (v4.0) and exposes pro phase angle data for form
 * comparison and suggestion generation.
 *
 * Key design decisions, carried over deliberately:
 * - Null angles (occluded landmarks) are returned as null, never silently
 *   replaced with defaults. Callers check for null and surface the data quality
 *   context to the user.
 * - [phaseAnglesWithFallback] is the method to use when a missing value would
 *   leave a gap; every substitution it makes comes back as a warning string.
 * - [baselineSummary] exposes cross-player mean and SD for range-based feedback
 *   that works even without a specific pro selected.
 * - [dataQualityFlags] exposes known issues so the UI can warn users.
 */
class ProBaselineDatabase(private val root: JsonObject) {

    /** Every player name present in the database. */
    val playerNames: List<String>
        get() = (root["players"] as? JsonObject)?.keys?.toList() ?: emptyList()

    /** Whether a player has data for the given throw type (`BH` or `FH`). */
    fun hasThrowType(playerName: String, throwType: String): Boolean {
        val player = players()[playerName] as? JsonObject ?: return false
        val throws = player["throws"] as? JsonObject ?: return false
        return throws.containsKey(throwType)
    }

    /**
     * Phase angle snapshots for one player, allowing null values.
     *
     * Returns `phase name -> {app angle key -> degrees?}`. Null means the
     * landmark was occluded or below confidence — do not replace it with a
     * default; surface a warning or skip that angle in scoring.
     */
    fun phaseAnglesNullable(
        playerName: String,
        throwType: String,
    ): Map<String, Map<String, Double?>> {
        val player = players()[playerName] as? JsonObject ?: return emptyMap()
        val throwData = (player["throws"] as? JsonObject)?.get(throwType) as? JsonObject
            ?: return emptyMap()
        val phases = throwData["phases"] as? JsonObject ?: return emptyMap()

        val angleMapping = angleMapping(throwType)
        val result = LinkedHashMap<String, Map<String, Double?>>()

        for (phaseName in phaseNames(throwType)) {
            val phaseData = phases[phaseName] as? JsonObject
            if (phaseData == null) {
                result[phaseName] = emptyMap()
                continue
            }
            val angles = LinkedHashMap<String, Double?>()
            for ((jsonKey, appKey) in angleMapping) {
                val raw = phaseData[jsonKey]
                angles[appKey] = if (raw == null || raw is JsonNull) {
                    null // Occluded — the caller must handle it.
                } else {
                    convertAngle(jsonKey, raw.jsonPrimitive.double())
                }
            }
            result[phaseName] = angles
        }
        return result
    }

    /** Phase angles, and the warnings raised while resolving them. */
    data class ResolvedPhaseAngles(
        val angles: Map<String, Map<String, Double>>,
        val qualityWarnings: List<String>,
    )

    /**
     * Phase angles with null values replaced by the cross-player baseline mean.
     *
     * Use this for scoring and waveform markers where a missing value would
     * cause a gap. Every substitution is noted in the warnings so the UI can
     * tell the user "Wysocki FH power pocket — lead leg occluded, using group
     * average".
     */
    fun phaseAnglesWithFallback(playerName: String, throwType: String): ResolvedPhaseAngles {
        val nullable = phaseAnglesNullable(playerName, throwType)
        val summary = baselineSummary(throwType)
        val warnings = ArrayList<String>()

        // Surface any pre-flagged issues first.
        for (flag in dataQualityFlags(playerName = playerName, throwType = throwType)) {
            val issue = (flag["issue"] as? JsonPrimitive)?.content.orEmpty()
            if (issue.isNotEmpty()) warnings += issue
        }

        val reverseMap = reverseMapping(throwType)
        val result = LinkedHashMap<String, Map<String, Double>>()

        for ((phaseName, phaseAngles) in nullable) {
            val resolved = LinkedHashMap<String, Double>()
            for ((appKey, value) in phaseAngles) {
                val jsonKey = reverseMap[appKey]
                if (value != null) {
                    resolved[appKey] = value
                } else if (jsonKey != null) {
                    val mean = summary[phaseName]?.get(jsonKey)?.get("mean")
                    if (mean != null) {
                        val fallback = convertAngle(jsonKey, mean)
                        resolved[appKey] = fallback
                        warnings += "$playerName $throwType $phaseName: $appKey occluded — " +
                            "using group mean (${format1(fallback)}°)"
                    }
                }
            }
            result[phaseName] = resolved
        }

        return ResolvedPhaseAngles(result, warnings)
    }

    /**
     * Cross-player mean and SD statistics per phase.
     *
     * Returns `phase name -> {json angle key -> {mean, sd, min, max, n}}`. Use
     * it for range-based feedback when no specific pro is selected.
     */
    fun baselineSummary(throwType: String): Map<String, Map<String, Map<String, Double>>> {
        val summary = root["baseline_summary"] as? JsonObject ?: return emptyMap()
        val typeData = summary[throwType] as? JsonObject ?: return emptyMap()

        val result = LinkedHashMap<String, Map<String, Map<String, Double>>>()
        for ((phaseName, angles) in typeData) {
            val angleObject = angles as? JsonObject ?: continue
            val perAngle = LinkedHashMap<String, Map<String, Double>>()
            for ((angleKey, stats) in angleObject) {
                val statsObject = stats as? JsonObject ?: continue
                perAngle[angleKey] = statsObject.mapNotNull { (statKey, statValue) ->
                    (statValue as? JsonPrimitive)?.doubleOrNull?.let { statKey to it }
                }.toMap()
            }
            result[phaseName] = perAngle
        }
        return result
    }

    /**
     * A human-readable summary for one angle at one phase, for example
     * "Pro mean: 71.6° (SD ±21.6°, n=5) · range 46.0–96.0°".
     */
    fun baselineDescription(
        throwType: String,
        phaseName: String,
        appAngleKey: String,
    ): String? {
        val jsonKey = reverseMapping(throwType)[appAngleKey] ?: return null
        val stats = baselineSummary(throwType)[phaseName]?.get(jsonKey) ?: return null

        val mean = stats["mean"] ?: return null
        val sd = stats["sd"]
        val min = stats["min"]
        val max = stats["max"]
        val n = stats["n"]?.toInt()

        val meanDisplay = format1(convertAngle(jsonKey, mean))
        val minDisplay = min?.let { format1(convertAngle(jsonKey, it)) } ?: "?"
        val maxDisplay = max?.let { format1(convertAngle(jsonKey, it)) } ?: "?"

        return buildString {
            append("Pro mean: $meanDisplay°")
            if (sd != null) {
                append(" (SD ±${format1(sd)}°")
                if (n != null) append(", n=$n")
                append(")")
            } else if (n != null) {
                append(" (n=$n)")
            }
            append(" · range $minDisplay–$maxDisplay°")
        }
    }

    /**
     * How many SDs a user angle deviates from the cross-player mean at a given
     * phase. Positive means above the mean, negative below.
     *
     * Returns null when baseline data is unavailable for this combination.
     */
    fun deviationInSD(
        throwType: String,
        phaseName: String,
        appAngleKey: String,
        userAngle: Double,
    ): Double? {
        val jsonKey = reverseMapping(throwType)[appAngleKey] ?: return null
        val stats = baselineSummary(throwType)[phaseName]?.get(jsonKey) ?: return null
        val mean = stats["mean"] ?: return null
        val sd = stats["sd"] ?: return null
        if (sd == 0.0) return null
        return (userAngle - convertAngle(jsonKey, mean)) / sd
    }

    /**
     * Known data quality issues from the JSON metadata, filtered by player
     * and/or throw type. Dataset-wide flags are always included.
     */
    fun dataQualityFlags(
        playerName: String? = null,
        throwType: String? = null,
    ): List<JsonObject> {
        val meta = root["metadata"] as? JsonObject ?: return emptyList()
        val flags = meta["data_quality_flags"] as? JsonArray ?: return emptyList()

        return flags.mapNotNull { it as? JsonObject }.filter { flag ->
            if ((flag["general"] as? JsonPrimitive)?.content == "true") return@filter true
            if (playerName != null) {
                val flagPlayer = (flag["player"] as? JsonPrimitive)?.content
                if (flagPlayer != null && flagPlayer != playerName) return@filter false
            }
            if (throwType != null) {
                val flagThrow = (flag["throw_type"] as? JsonPrimitive)?.content
                if (flagThrow != null && flagThrow != throwType) return@filter false
            }
            true
        }
    }

    /**
     * True if a specific player, throw type, and phase combination has known
     * occlusion or reliability issues.
     */
    fun hasQualityWarning(playerName: String, throwType: String, phaseName: String): Boolean {
        for (flag in dataQualityFlags(playerName = playerName, throwType = throwType)) {
            if ((flag["phase"] as? JsonPrimitive)?.content == phaseName) return true
            val phases = flag["phases"] as? JsonArray ?: continue
            if (phases.any { (it as? JsonPrimitive)?.content == phaseName }) return true
        }
        return false
    }

    private fun players(): JsonObject = root["players"] as? JsonObject ?: JsonObject(emptyMap())

    companion object {
        private val json = Json { ignoreUnknownKeys = true; isLenient = true }

        fun parse(jsonString: String): ProBaselineDatabase =
            ProBaselineDatabase(json.parseToJsonElement(jsonString).jsonObject)

        /** The ordered phase names for a throw type. */
        fun phaseNames(throwType: String): List<String> =
            if (throwType == ThrowTypes.BACKHAND) {
                listOf("reach_back", "power_pocket", "release", "follow_through")
            } else {
                listOf("wind_up", "power_pocket", "release", "follow_through")
            }

        /**
         * Maps JSON angle keys to app angle keys.
         *
         * BH (RHBH): lead knee = right, trail knee = left.
         * FH (RHFH): lead knee = left, trail knee = right.
         * All pros in the database are right-handed, so the throwing arm is the
         * right arm throughout.
         */
        fun angleMapping(throwType: String): Map<String, String> =
            if (throwType == ThrowTypes.BACKHAND) {
                mapOf(
                    "elbow_angle_deg" to "rightElbowAngle",
                    "shoulder_flexion_deg" to "rightShoulderAngle",
                    "lead_knee_flexion_deg" to "rightKneeAngle", // RHBH lead = R
                    "trail_knee_flexion_deg" to "leftKneeAngle", // RHBH trail = L
                    "trunk_lateral_tilt_deg" to "spineAngle",
                    "off_arm_elbow_angle_deg" to "leftElbowAngle",
                    "off_arm_shoulder_angle_deg" to "leftShoulderAngle",
                    "x_factor_deg" to "xFactor",
                )
            } else {
                mapOf(
                    "elbow_angle_deg" to "rightElbowAngle",
                    "shoulder_flexion_deg" to "rightShoulderAngle",
                    "lead_knee_flexion_deg" to "leftKneeAngle", // RHFH lead = L
                    "trail_knee_flexion_deg" to "rightKneeAngle", // RHFH trail = R
                    "trunk_lateral_tilt_deg" to "spineAngle",
                    "off_arm_elbow_angle_deg" to "leftElbowAngle",
                    "off_arm_shoulder_angle_deg" to "leftShoulderAngle",
                    "x_factor_deg" to "xFactor",
                )
            }

        /** The reverse mapping: app key to JSON key. */
        fun reverseMapping(throwType: String): Map<String, String> =
            angleMapping(throwType).entries.associate { (jsonKey, appKey) -> appKey to jsonKey }

        /**
         * Converts a raw JSON value into the app's angle convention.
         *
         * `trunk_lateral_tilt_deg` is 0 when upright; `spineAngle` is 90 when
         * upright.
         */
        fun convertAngle(jsonKey: String, raw: Double): Double =
            if (jsonKey == "trunk_lateral_tilt_deg") 90.0 - raw else raw

        private fun format1(value: Double) = String.format(java.util.Locale.US, "%.1f", value)

        private fun JsonPrimitive.double(): Double =
            doubleOrNull ?: intOrNull?.toDouble() ?: 0.0
    }
}
