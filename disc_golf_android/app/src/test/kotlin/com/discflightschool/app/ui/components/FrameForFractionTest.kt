package com.discflightschool.app.ui.components

import org.junit.Assert.assertEquals
import org.junit.Test

/** Scrubbing an angle chart back to the frame it was measured on. */
class FrameForFractionTest {

    @Test
    fun `the ends of the chart are the ends of the clip`() {
        assertEquals(0, frameForFraction(0.0, frameCount = 100))
        assertEquals(99, frameForFraction(1.0, frameCount = 100))
    }

    @Test
    fun `the middle of the chart is the middle frame`() {
        assertEquals(50, frameForFraction(0.5, frameCount = 101))
    }

    @Test
    fun `a tap outside the plot area clamps`() {
        assertEquals(0, frameForFraction(-0.2, frameCount = 60))
        assertEquals(59, frameForFraction(1.4, frameCount = 60))
    }

    @Test
    fun `a single frame analysis has nowhere to scrub`() {
        assertEquals(0, frameForFraction(0.7, frameCount = 1))
        assertEquals(0, frameForFraction(0.7, frameCount = 0))
    }
}
