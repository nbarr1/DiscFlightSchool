package com.discflightschool.core.model

import com.discflightschool.core.util.DateTimes
import java.time.Instant
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Metadata for a locally installed detector model. */
data class DetectorModelMetadata(
    val version: String,
    val sha256: String,
    val path: String,
    val installedAt: Instant,
) {
    fun toJson(): JsonObject = buildJsonObject {
        put("version", JsonPrimitive(version))
        put("sha256", JsonPrimitive(sha256))
        put("path", JsonPrimitive(path))
        put("installedAt", JsonPrimitive(DateTimes.format(installedAt)))
    }

    companion object {
        fun fromJson(json: JsonObject): DetectorModelMetadata = DetectorModelMetadata(
            version = json.getValue("version").jsonPrimitive.content,
            sha256 = json.getValue("sha256").jsonPrimitive.content,
            path = json.getValue("path").jsonPrimitive.content,
            installedAt = DateTimes.parse(json.getValue("installedAt").jsonPrimitive.content),
        )
    }
}

/** The server response shape from `GET /api/model/version`. */
data class DetectorModelVersion(
    val version: String,
    val sha256: String,
    val url: String,
) {
    val hasModel: Boolean get() = version != "none" && sha256.isNotEmpty() && url.isNotEmpty()

    companion object {
        fun fromJson(json: JsonObject): DetectorModelVersion = DetectorModelVersion(
            version = json["version"]?.jsonPrimitive?.content ?: "none",
            sha256 = json["sha256"]?.jsonPrimitive?.content ?: "",
            url = json["url"]?.jsonPrimitive?.content ?: "",
        )
    }
}
