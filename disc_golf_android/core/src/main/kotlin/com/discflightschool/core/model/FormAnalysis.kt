package com.discflightschool.core.model

import com.discflightschool.core.geometry.Vec2
import com.discflightschool.core.util.DateTimes
import java.time.Instant
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * One analysed video frame: the joint angles measured in it, the landmark
 * positions they were measured from, and the per-landmark depth and confidence
 * the pose detector reported.
 */
data class FormFrame(
    /** Offset from the start of the analysed range, in milliseconds. */
    val timestampMs: Long,
    val angles: MutableMap<String, Double> = mutableMapOf(),
    val keyPoints: MutableMap<String, Vec2> = mutableMapOf(),
    /**
     * Z-depth per landmark from ML Kit (relative, same scale as x).
     * Positive means in front of the camera. Empty for manually corrected frames.
     */
    val landmarkZ: Map<String, Double> = emptyMap(),
    /**
     * Per-landmark detection confidence (0-1) from ML Kit likelihood.
     * Empty for manually corrected frames — treat those as fully trusted.
     */
    val landmarkConf: Map<String, Double> = emptyMap(),
    val imageWidth: Double? = null,
    val imageHeight: Double? = null,
) {
    /**
     * A frame whose mutable maps are its own.
     *
     * `data class` copy() would share the same `angles` and `keyPoints`
     * instances, so an editor working on the copy would still write through to
     * the original.
     */
    fun deepCopy(): FormFrame = copy(
        angles = angles.toMutableMap(),
        keyPoints = keyPoints.toMutableMap(),
    )

    fun toJson(): JsonObject = buildJsonObject {
        put("timestamp", JsonPrimitive(timestampMs))
        put("angles", JsonObject(angles.mapValues { JsonPrimitive(it.value) }))
        put(
            "keyPoints",
            JsonObject(
                keyPoints.mapValues { (_, point) ->
                    buildJsonObject {
                        put("dx", JsonPrimitive(point.x))
                        put("dy", JsonPrimitive(point.y))
                    }
                },
            ),
        )
        if (landmarkZ.isNotEmpty()) {
            put("landmarkZ", JsonObject(landmarkZ.mapValues { JsonPrimitive(it.value) }))
        }
        if (landmarkConf.isNotEmpty()) {
            put("landmarkConf", JsonObject(landmarkConf.mapValues { JsonPrimitive(it.value) }))
        }
        imageWidth?.let { put("imageWidth", JsonPrimitive(it)) }
        imageHeight?.let { put("imageHeight", JsonPrimitive(it)) }
    }

    companion object {
        fun fromJson(json: JsonObject): FormFrame {
            val angles = json["angles"]?.jsonObject
                ?.mapValues { it.value.jsonPrimitive.double }
                ?.toMutableMap()
                ?: mutableMapOf()

            val keyPoints = json["keyPoints"]?.jsonObject
                ?.mapValues { (_, value) ->
                    val point = value.jsonObject
                    Vec2(
                        point.getValue("dx").jsonPrimitive.double,
                        point.getValue("dy").jsonPrimitive.double,
                    )
                }
                ?.toMutableMap()
                ?: mutableMapOf()

            return FormFrame(
                timestampMs = json.getValue("timestamp").jsonPrimitive.long(),
                angles = angles,
                keyPoints = keyPoints,
                landmarkZ = json["landmarkZ"]?.jsonObject
                    ?.mapValues { it.value.jsonPrimitive.double } ?: emptyMap(),
                landmarkConf = json["landmarkConf"]?.jsonObject
                    ?.mapValues { it.value.jsonPrimitive.double } ?: emptyMap(),
                imageWidth = json["imageWidth"]?.jsonPrimitive?.double,
                imageHeight = json["imageHeight"]?.jsonPrimitive?.double,
            )
        }

        private fun JsonPrimitive.long(): Long = content.toDouble().toLong()
    }
}

/** A complete form analysis: every frame of a throw, plus how it scored. */
data class FormAnalysis(
    val id: String,
    val date: Instant,
    val videoPath: String,
    val frames: List<FormFrame>,
    val score: Double,
    /** True when pose detection failed and mock data was substituted. */
    var isMock: Boolean = false,
    /**
     * Why the analysis fell back to mock data, when it did. Null means either a
     * real analysis, or a fallback because no pose was found in any frame (as
     * opposed to the analysis throwing).
     */
    var failureReason: String? = null,
) {
    /** The analysis with every frame's mutable state detached from this one. */
    fun deepCopy(): FormAnalysis = copy(frames = frames.map { it.deepCopy() })

    fun toJson(): JsonObject = buildJsonObject {
        put("id", JsonPrimitive(id))
        put("date", JsonPrimitive(DateTimes.format(date)))
        put("videoPath", JsonPrimitive(videoPath))
        put("frames", kotlinx.serialization.json.JsonArray(frames.map { it.toJson() }))
        put("score", JsonPrimitive(score))
        put("isMock", JsonPrimitive(isMock))
        put("failureReason", failureReason?.let { JsonPrimitive(it) } ?: kotlinx.serialization.json.JsonNull)
    }

    companion object {
        fun fromJson(json: JsonObject): FormAnalysis = FormAnalysis(
            id = json.getValue("id").jsonPrimitive.content,
            date = DateTimes.parse(json.getValue("date").jsonPrimitive.content),
            videoPath = json.getValue("videoPath").jsonPrimitive.content,
            frames = json.getValue("frames").jsonArray.map { FormFrame.fromJson(it.jsonObject) },
            score = json.getValue("score").jsonPrimitive.double,
            isMock = json["isMock"]?.asBooleanOrNull() ?: false,
            failureReason = json["failureReason"]?.asStringOrNull(),
        )

        private fun JsonElement.asBooleanOrNull(): Boolean? =
            runCatching { jsonPrimitive.boolean }.getOrNull()

        private fun JsonElement.asStringOrNull(): String? =
            runCatching { jsonPrimitive }.getOrNull()
                ?.takeIf { it !is kotlinx.serialization.json.JsonNull && it.isString }
                ?.content
    }
}

/** A measured reference throw from a professional player. */
data class ProFormData(
    val playerName: String,
    val analysis: FormAnalysis,
    val description: String,
)

/** Which throw the analysis is of. */
object ThrowTypes {
    const val BACKHAND = "BH"
    const val FOREHAND = "FH"
}
