package com.discflightschool.app.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Choosing which tracked frames get a pre-rendered trail.
 *
 * Every sampled frame costs a full-resolution bitmap, so a long clip has to
 * drop frames — but dropping the last one would end the drawn-on trail before
 * the disc lands.
 */
class FlightVideoExporterTest {

    @Test
    fun `a short flight is used as is`() {
        val frames = (0 until 40).toList()
        assertEquals(frames, FlightVideoExporter.sampleFrames(frames, max = 90))
    }

    @Test
    fun `a long flight is sampled down to the cap`() {
        val frames = (0 until 500).toList()
        val sampled = FlightVideoExporter.sampleFrames(frames, max = 90)
        assertEquals(90, sampled.size)
    }

    @Test
    fun `sampling keeps both ends and the order`() {
        val frames = (0 until 500).toList()
        val sampled = FlightVideoExporter.sampleFrames(frames, max = 90)
        assertEquals(0, sampled.first())
        assertEquals(499, sampled.last())
        assertEquals(sampled.sorted(), sampled)
    }

    @Test
    fun `sampling spreads the frames evenly`() {
        val frames = (0 until 500).toList()
        val sampled = FlightVideoExporter.sampleFrames(frames, max = 90)
        val gaps = sampled.zipWithNext { a, b -> b - a }
        assertTrue("gaps were $gaps", gaps.all { it in 5..6 })
    }

    @Test
    fun `a sparse track sampled to a smaller cap keeps real frame numbers`() {
        val frames = listOf(3, 9, 14, 20, 27, 31)
        val sampled = FlightVideoExporter.sampleFrames(frames, max = 3)
        assertEquals(listOf(3, 20, 31), sampled)
        assertTrue(sampled.all { it in frames })
    }
}
