package com.discflightschool.core.detection

import kotlin.math.floor
import kotlin.math.roundToLong

/**
 * Which timestamps in a clip to decode a frame at.
 *
 * Extraction used to be an FFmpeg `fps=` filter pass; on Android it is a series
 * of seeks against the platform decoder, so the sampling plan has to be built
 * explicitly. The failure mode is silent — an off-by-one start offset yields
 * frames from the wrong part of the clip, which still look perfectly plausible
 * — so the plan is pure and tested rather than computed inline at the call site.
 */
object FrameSampling {

    /**
     * Timestamps, in milliseconds from the start of the file, to sample at
     * [fps] across the trimmed range.
     *
     * Index 0 in the returned list is frame index 0 in tracker space: the first
     * frame at or after [startMs].
     */
    fun sampleTimestamps(
        fps: Double,
        maxFrames: Int,
        startMs: Long,
        endMs: Long?,
        durationMs: Long? = null,
    ): List<Long> {
        require(fps > 0) { "fps must be greater than zero, got $fps" }
        if (maxFrames <= 0) return emptyList()

        val intervalMs = 1000.0 / fps
        val end = listOfNotNull(endMs, durationMs).minOrNull()

        val count = if (end == null) {
            maxFrames
        } else {
            val spanMs = end - startMs
            if (spanMs < 0) return emptyList()
            // A span of N intervals contains N+1 frame boundaries.
            val fromSpan = floor(spanMs / intervalMs).toInt() + 1
            minOf(maxFrames, fromSpan)
        }

        return (0 until count).map { startMs + (it * intervalMs).roundToLong() }
    }
}
