package com.discflightschool.app.ui.screens.formcoach

import com.discflightschool.app.video.FrameExtractor
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Timestamps to analysis frames.
 *
 * The phase a user marks is stored as an index into the sampled sequence, not
 * as a time, so an off-by-one here would compare the wrong frame against the
 * pro baseline for the rest of the session.
 */
class FrameIndexTest {

    @Test
    fun `the trim start is frame zero`() {
        assertEquals(0, frameIndexFor(timestampMs = 1_200, analysisStartMs = 1_200))
    }

    @Test
    fun `each sampling interval advances one frame`() {
        val interval = FrameExtractor.POSE_INTERVAL_MS
        assertEquals(1, frameIndexFor(interval, 0))
        assertEquals(10, frameIndexFor(interval * 10, 0))
        assertEquals(10, frameIndexFor(2_000 + interval * 10, 2_000))
    }

    @Test
    fun `a timestamp inside an interval stays on the frame it started`() {
        val interval = FrameExtractor.POSE_INTERVAL_MS
        assertEquals(3, frameIndexFor(interval * 3 + interval - 1, 0))
    }

    @Test
    fun `a timestamp before the trim start clamps to zero`() {
        // Seeking backwards past the trim handle should not index off the front
        // of the frame list.
        assertEquals(0, frameIndexFor(timestampMs = 500, analysisStartMs = 2_000))
    }
}
