package com.discflightschool.core.util

import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeParseException

/**
 * ISO-8601 parsing and formatting compatible with what earlier versions of the
 * app persisted.
 *
 * Records written before this rewrite carry timestamps without a zone offset
 * (a local `DateTime.toIso8601String()`), so a strict [Instant.parse] would
 * reject a user's own saved history. Parsing falls back to interpreting such a
 * value in the device's zone, which is how it was written.
 */
object DateTimes {

    fun parse(value: String): Instant = try {
        Instant.parse(value)
    } catch (e: DateTimeParseException) {
        LocalDateTime.parse(value).atZone(ZoneId.systemDefault()).toInstant()
    }

    fun parseOrNull(value: String?): Instant? =
        value?.takeIf { it.isNotBlank() }?.let {
            runCatching { parse(it) }.getOrNull()
        }

    fun format(instant: Instant): String = instant.toString()
}
