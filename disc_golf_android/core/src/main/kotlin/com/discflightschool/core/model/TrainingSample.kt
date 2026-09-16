package com.discflightschool.core.model

import com.discflightschool.core.util.DateTimes
import java.time.Instant
import java.util.Locale
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonPrimitive

/** One labelled training image collected from a user-marked keyframe. */
data class TrainingSample(
    val id: String,
    val imagePath: String,
    val cropPath: String,
    val centerX: Double,
    val centerY: Double,
    val boxWidth: Double,
    val boxHeight: Double,
    val frameIndex: Int,
    val imageWidth: Int,
    val imageHeight: Int,
    val createdAt: Instant,
    val uploaded: Boolean = false,
) {
    fun toJson(): JsonObject = buildJsonObject {
        put("id", JsonPrimitive(id))
        put("imagePath", JsonPrimitive(imagePath))
        put("cropPath", JsonPrimitive(cropPath))
        put("centerX", JsonPrimitive(centerX))
        put("centerY", JsonPrimitive(centerY))
        put("boxWidth", JsonPrimitive(boxWidth))
        put("boxHeight", JsonPrimitive(boxHeight))
        put("frameIndex", JsonPrimitive(frameIndex))
        put("imageWidth", JsonPrimitive(imageWidth))
        put("imageHeight", JsonPrimitive(imageHeight))
        put("createdAt", JsonPrimitive(DateTimes.format(createdAt)))
        put("uploaded", JsonPrimitive(uploaded))
    }

    /**
     * A YOLO format label line: `class_id center_x center_y width height`.
     *
     * Values are clamped to normalized YOLO bounds so persisted legacy samples
     * cannot generate labels the training server rejects.
     */
    fun toYoloLabel(): String {
        val safeCenterX = centerX.coerceIn(0.0, 1.0)
        val safeCenterY = centerY.coerceIn(0.0, 1.0)
        val safeBoxWidth = boxWidth.coerceIn(0.000001, 1.0)
        val safeBoxHeight = boxHeight.coerceIn(0.000001, 1.0)
        return "0 ${fixed6(safeCenterX)} ${fixed6(safeCenterY)} " +
            "${fixed6(safeBoxWidth)} ${fixed6(safeBoxHeight)}"
    }

    private fun fixed6(value: Double) = String.format(Locale.US, "%.6f", value)

    companion object {
        fun fromJson(json: JsonObject): TrainingSample = TrainingSample(
            id = json.getValue("id").jsonPrimitive.content,
            imagePath = json.getValue("imagePath").jsonPrimitive.content,
            cropPath = json.getValue("cropPath").jsonPrimitive.content,
            centerX = json.getValue("centerX").jsonPrimitive.double,
            centerY = json.getValue("centerY").jsonPrimitive.double,
            boxWidth = json.getValue("boxWidth").jsonPrimitive.double,
            boxHeight = json.getValue("boxHeight").jsonPrimitive.double,
            frameIndex = json.getValue("frameIndex").jsonPrimitive.double.toInt(),
            imageWidth = json.getValue("imageWidth").jsonPrimitive.double.toInt(),
            imageHeight = json.getValue("imageHeight").jsonPrimitive.double.toInt(),
            createdAt = DateTimes.parse(json.getValue("createdAt").jsonPrimitive.content),
            uploaded = runCatching { json["uploaded"]?.jsonPrimitive?.boolean }.getOrNull() ?: false,
        )
    }
}
