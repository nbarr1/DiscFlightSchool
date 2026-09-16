package com.discflightschool.app.ui

import androidx.compose.ui.graphics.Color
import com.discflightschool.app.ui.theme.AppColors
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** Date, score, and colour formatting shared across the history screens. */
object Formatting {

    private val timeFormatter = DateTimeFormatter.ofPattern("HH:mm")
    private val dateFormatter = DateTimeFormatter.ofPattern("M/d/yyyy")
    private val dateTimeFormatter = DateTimeFormatter.ofPattern("MMM d, HH:mm")

    /** "Today 14:32", "Yesterday", or a plain date for anything older. */
    fun relativeDate(instant: Instant, zone: ZoneId = ZoneId.systemDefault()): String {
        val date = instant.atZone(zone)
        val today = LocalDate.now(zone)
        return when (date.toLocalDate()) {
            today -> "Today ${timeFormatter.format(date)}"
            today.minusDays(1) -> "Yesterday"
            else -> dateFormatter.format(date)
        }
    }

    fun dateTime(instant: Instant, zone: ZoneId = ZoneId.systemDefault()): String =
        dateTimeFormatter.format(instant.atZone(zone))

    /** "3 days ago", or "just now" for anything inside the last minute. */
    fun timeAgo(instant: Instant, now: Instant = Instant.now()): String {
        val elapsed = Duration.between(instant, now)
        return when {
            elapsed.toMinutes() < 1 -> "just now"
            elapsed.toHours() < 1 -> "${elapsed.toMinutes()} min ago"
            elapsed.toDays() < 1 -> "${elapsed.toHours()} h ago"
            elapsed.toDays() < 30 -> "${elapsed.toDays()} days ago"
            else -> relativeDate(instant)
        }
    }

    /** A score relative to par, with the sign a scorecard expects. */
    fun scoreToPar(value: Int): String = when {
        value == 0 -> "E"
        value > 0 -> "+$value"
        else -> value.toString()
    }

    fun weighted(value: Double): String = String.format(Locale.US, "%+.1f", value)

    fun decimal(value: Double, digits: Int = 1): String =
        String.format(Locale.US, "%.${digits}f", value)

    fun degrees(value: Double): String = "${decimal(value)}°"

    fun percent(fraction: Double): String = "${(fraction * 100).toInt()}%"

    /** Green through red, by how hard a spun challenge is. */
    fun difficultyColor(multiplier: Double): Color = when {
        multiplier < 1.4 -> AppColors.Good
        multiplier < 2.0 -> AppColors.Warning
        else -> AppColors.Bad
    }

    /** Green through red, by how close a form score is to the pro baseline. */
    fun scoreColor(score: Double): Color = when {
        score >= 80 -> AppColors.Good
        score >= 60 -> AppColors.Warning
        else -> AppColors.Bad
    }

    /** Duration as m:ss, the form video scrubbers' readout. */
    fun clock(millis: Long): String {
        val totalSeconds = millis / 1000
        val minutes = totalSeconds / 60
        val seconds = totalSeconds % 60
        return "%d:%02d".format(minutes, seconds)
    }

    /** A phase name from the pro database, in sentence case. */
    fun phaseLabel(phase: String): String = phase
        .replace('_', ' ')
        .replaceFirstChar { it.uppercase() }

    /** An angle key from the analysis, as a human-readable label. */
    fun angleLabel(key: String): String = when (key) {
        "rightElbowAngle" -> "Right elbow"
        "leftElbowAngle" -> "Left elbow"
        "rightShoulderAngle" -> "Right shoulder"
        "leftShoulderAngle" -> "Left shoulder"
        "rightKneeAngle" -> "Right knee"
        "leftKneeAngle" -> "Left knee"
        "spineAngle" -> "Trunk lean"
        "xFactor" -> "Hip-shoulder separation"
        else -> key
    }
}
