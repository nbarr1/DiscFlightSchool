package com.discflightschool.core.model

import com.discflightschool.core.util.DateTimes
import java.time.Instant
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** One saved form analysis session — a lightweight record for history display. */
data class FormSessionRecord(
    val id: String,
    val date: Instant,
    val score: Double,
    /** Either `BH` or `FH`. */
    val throwType: String,
    val proPlayer: String? = null,
    val frameCount: Int,
    /** Per-angle averages, kept for trend charting. */
    val avgAngles: Map<String, Double> = emptyMap(),
) {
    fun toJson(): JsonObject = buildJsonObject {
        put("id", JsonPrimitive(id))
        put("date", JsonPrimitive(DateTimes.format(date)))
        put("score", JsonPrimitive(score))
        put("throwType", JsonPrimitive(throwType))
        put("proPlayer", proPlayer?.let { JsonPrimitive(it) } ?: JsonNull)
        put("frameCount", JsonPrimitive(frameCount))
        put("avgAngles", JsonObject(avgAngles.mapValues { JsonPrimitive(it.value) }))
    }

    companion object {
        fun fromJson(json: JsonObject): FormSessionRecord = FormSessionRecord(
            id = json.getValue("id").jsonPrimitive.content,
            date = DateTimes.parse(json.getValue("date").jsonPrimitive.content),
            score = json.getValue("score").jsonPrimitive.double,
            throwType = json["throwType"]?.jsonPrimitive?.contentOrNull() ?: ThrowTypes.BACKHAND,
            proPlayer = json["proPlayer"]?.jsonPrimitive?.contentOrNull(),
            frameCount = json.getValue("frameCount").jsonPrimitive.double.toInt(),
            avgAngles = json["avgAngles"]?.jsonObject
                ?.mapValues { it.value.jsonPrimitive.double } ?: emptyMap(),
        )

        private fun JsonPrimitive.contentOrNull(): String? =
            if (this is JsonNull) null else content.takeIf { it.isNotEmpty() }
    }
}
