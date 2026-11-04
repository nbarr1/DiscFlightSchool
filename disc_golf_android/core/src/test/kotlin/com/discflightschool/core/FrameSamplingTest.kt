package com.discflightschool.core

import com.discflightschool.core.video.FrameSampling
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FrameSamplingTest {

    // ── frame sampling ───────────────────────────────────────────────────

    @Test
    fun `sampling starts at the trim start, not the start of the file`() {
        val timestamps = FrameSampling.sampleTimestamps(
            fps = 10.0,
            maxFrames = 300,
            startMs = 1500,
            endMs = 2000,
        )

        assertEquals(1500L, timestamps.first())
        assertEquals(listOf(1500L, 1600L, 1700L, 1800L, 1900L, 2000L), timestamps)
    }

    @Test
    fun `sampling covers the trimmed span, not the whole cap`() {
        // A six-second trim at 10fps is 61 frame boundaries.
        val timestamps = FrameSampling.sampleTimestamps(
            fps = 10.0,
            maxFrames = 300,
            startMs = 2000,
            endMs = 8000,
        )
        assertEquals(61, timestamps.size)
        assertEquals(8000L, timestamps.last())
    }

    @Test
    fun `sampling honours the frame cap`() {
        val timestamps = FrameSampling.sampleTimestamps(
            fps = 10.0,
            maxFrames = 5,
            startMs = 0,
            endMs = 60_000,
        )
        assertEquals(5, timestamps.size)
    }

    @Test
    fun `sampling stops at the clip duration when there is no trim end`() {
        val timestamps = FrameSampling.sampleTimestamps(
            fps = 10.0,
            maxFrames = 300,
            startMs = 0,
            endMs = null,
            durationMs = 500,
        )
        assertEquals(6, timestamps.size)
    }

    @Test
    fun `an inverted span samples nothing`() {
        assertTrue(
            FrameSampling.sampleTimestamps(
                fps = 10.0,
                maxFrames = 300,
                startMs = 5000,
                endMs = 1000,
            ).isEmpty(),
        )
    }
}
