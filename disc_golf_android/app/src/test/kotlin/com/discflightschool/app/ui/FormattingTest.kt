package com.discflightschool.app.ui

import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The readouts the history and scorecard screens share.
 *
 * Pinned in a test because the scorecard convention — "E" for even, an explicit
 * "+" over par — is what a player expects to read, and a plain `toString` on
 * the same numbers would silently break it.
 */
class FormattingTest {

    private val utc = ZoneId.of("UTC")

    @Test
    fun `score to par uses the scorecard convention`() {
        assertEquals("E", Formatting.scoreToPar(0))
        assertEquals("+1", Formatting.scoreToPar(1))
        assertEquals("+12", Formatting.scoreToPar(12))
        assertEquals("-3", Formatting.scoreToPar(-3))
    }

    @Test
    fun `clock pads the seconds`() {
        assertEquals("0:00", Formatting.clock(0))
        assertEquals("0:05", Formatting.clock(5_400))
        assertEquals("1:00", Formatting.clock(60_000))
        assertEquals("12:34", Formatting.clock(754_000))
    }

    @Test
    fun `clock truncates rather than rounds up`() {
        // Rounding would show 1:00 while the scrubber still sits on 59.9s.
        assertEquals("0:59", Formatting.clock(59_999))
    }

    @Test
    fun `decimals and percentages use a fixed locale`() {
        assertEquals("1.5", Formatting.decimal(1.46))
        assertEquals("1.46", Formatting.decimal(1.4649, digits = 2))
        assertEquals("90.0°", Formatting.degrees(90.0))
        assertEquals("+2.5", Formatting.weighted(2.45))
        assertEquals("-2.5", Formatting.weighted(-2.45))
        assertEquals("83%", Formatting.percent(0.834))
    }

    @Test
    fun `relative date names today and yesterday`() {
        val today = LocalDate.now(utc)
        val thisAfternoon = LocalDateTime.of(today, LocalTime.of(14, 32))
            .atZone(utc)
            .toInstant()
        assertEquals("Today 14:32", Formatting.relativeDate(thisAfternoon, utc))

        val yesterday = LocalDateTime.of(today.minusDays(1), LocalTime.NOON)
            .atZone(utc)
            .toInstant()
        assertEquals("Yesterday", Formatting.relativeDate(yesterday, utc))
    }

    @Test
    fun `relative date falls back to a plain date`() {
        val older = LocalDateTime.of(2024, 3, 7, 9, 15).atZone(utc).toInstant()
        assertEquals("3/7/2024", Formatting.relativeDate(older, utc))
    }

    @Test
    fun `time ago steps through the units`() {
        val now = Instant.parse("2025-06-01T12:00:00Z")
        assertEquals("just now", Formatting.timeAgo(now.minusSeconds(20), now))
        assertEquals("5 min ago", Formatting.timeAgo(now.minusSeconds(300), now))
        assertEquals("3 h ago", Formatting.timeAgo(now.minus(3, ChronoUnit.HOURS), now))
        assertEquals("9 days ago", Formatting.timeAgo(now.minus(9, ChronoUnit.DAYS), now))
    }

    @Test
    fun `phase and angle labels are readable`() {
        assertEquals("Follow through", Formatting.phaseLabel("follow_through"))
        assertEquals("Reach back", Formatting.phaseLabel("reach_back"))
        assertEquals("Right elbow", Formatting.angleLabel("rightElbowAngle"))
        assertEquals("Hip-shoulder separation", Formatting.angleLabel("xFactor"))
        // An angle the pro database adds later still renders as something.
        assertEquals("wristAngle", Formatting.angleLabel("wristAngle"))
    }
}
