package com.discflightschool.core.detection

import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * The geometry shared by every stage after inference: what counts as a
 * plausible flight path, how tightly to search for the disc next frame, and how
 * to fill the gaps.
 */
object Trajectory {

    /**
     * Maximum normalized distance a detection can jump per frame-step during
     * spatial coherence filtering (8% of the frame dimension).
     *
     * This is also the single source of truth for how wide the tracking-mode
     * search window is (see [searchWindowSizeFor]): a window wider than what
     * this constant allows would accept detections that
     * [filterSpatialCoherence] then discards downstream as an impossible jump,
     * silently undoing the tracker's work.
     */
    const val MAX_JUMP_PER_FRAME = 0.08

    /** Maximum consecutive frames to skip when building a coherent chain. */
    const val MAX_CHAIN_GAP = 5

    /**
     * How much wider than the coherence filter's raw per-frame budget the
     * tracking search window is, to absorb prediction error on top of the
     * motion the velocity estimate already accounts for.
     */
    const val TRACKING_WINDOW_MARGIN = 1.5
    const val MIN_TRACKING_WINDOW_SIZE = 0.15
    const val MAX_TRACKING_WINDOW_SIZE = 0.5

    /**
     * Frames the tracker will coast on velocity alone (no confirmed detection)
     * before giving up the lock and reverting to full-frame discovery. Matches
     * [MAX_CHAIN_GAP] — there is no point tolerating a gap here that the
     * coherence filter will not bridge anyway.
     */
    const val MAX_OCCLUSION_FRAMES = MAX_CHAIN_GAP

    /**
     * Exponential smoothing factor applied to new velocity estimates, so a
     * single noisy detection does not yank the predicted search window off the
     * disc's real trajectory.
     */
    const val VELOCITY_SMOOTHING = 0.6

    /** The largest gap, in frames, that interpolation will bridge. */
    const val MAX_INTERPOLATION_GAP = 10

    /**
     * Search-window side length, normalized to the frame's shorter dimension,
     * for a track that has not been confirmed in [frameGap] frames.
     */
    fun searchWindowSizeFor(frameGap: Int): Double {
        val gap = frameGap.coerceIn(1, MAX_OCCLUSION_FRAMES + 1)
        val size = MAX_JUMP_PER_FRAME * gap * 2 * TRACKING_WINDOW_MARGIN
        return size.coerceIn(MIN_TRACKING_WINDOW_SIZE, MAX_TRACKING_WINDOW_SIZE)
    }

    /**
     * Picks the candidate whose position best matches ([predictedX],
     * [predictedY]) — the track's last known position plus motion prediction —
     * instead of blindly taking the highest-confidence or largest detection.
     *
     * A small confidence term only breaks close ties; motion consistency
     * dominates, since a distant high-confidence blob is more likely clutter (a
     * hand, a second disc, a shadow) than the tracked disc suddenly
     * teleporting.
     */
    fun selectClosestCandidate(
        candidates: List<DiscDetection>,
        predictedX: Double,
        predictedY: Double,
    ): DiscDetection {
        var best = candidates.first()
        var bestScore = Double.POSITIVE_INFINITY
        for (candidate in candidates) {
            val dx = candidate.x - predictedX
            val dy = candidate.y - predictedY
            val score = hypot(dx, dy) - candidate.confidence * 0.02
            if (score < bestScore) {
                bestScore = score
                best = candidate
            }
        }
        return best
    }

    /**
     * Find the longest spatially coherent chain of detections.
     *
     * This is the key filter: a real disc follows a smooth trajectory, while
     * noise is scattered randomly.
     */
    fun filterSpatialCoherence(
        detections: List<DiscDetection>,
        totalFrames: Int,
        maxJumpPerFrame: Double = MAX_JUMP_PER_FRAME,
        maxGap: Int = MAX_CHAIN_GAP,
    ): List<DiscDetection> {
        if (detections.size < 3) return detections

        val sorted = detections.sortedBy { it.frameIndex }
        val byFrame = HashMap<Int, DiscDetection>(sorted.size)
        for (detection in sorted) {
            byFrame[detection.frameIndex] = detection
        }

        var bestChain: List<DiscDetection> = emptyList()

        for (startIdx in sorted.indices) {
            val chain = ArrayList<DiscDetection>()
            chain += sorted[startIdx]
            var last = sorted[startIdx]

            var frame = last.frameIndex + 1
            while (frame < totalFrames) {
                val detection = byFrame[frame]
                if (detection == null) {
                    if (frame - last.frameIndex > maxGap) break
                    frame++
                    continue
                }

                val frameGap = detection.frameIndex - last.frameIndex
                val maxDist = maxJumpPerFrame * frameGap
                val dist = sqrt(
                    (detection.x - last.x) * (detection.x - last.x) +
                        (detection.y - last.y) * (detection.y - last.y),
                )

                if (dist <= maxDist) {
                    chain += detection
                    last = detection
                } else if (frame - last.frameIndex > maxGap) {
                    // Too far to be the same disc, and now too old to wait for.
                    break
                }
                frame++
            }

            if (chain.size > bestChain.size) {
                bestChain = chain
            }

            // Early termination: a chain covering more than 40% of the frames is
            // good enough to stop searching.
            if (bestChain.size > totalFrames * 0.4) break
        }

        return bestChain
    }

    /** Smooth detections using a moving-average window. */
    fun smoothDetections(
        detections: List<DiscDetection>,
        windowSize: Int = 3,
    ): List<DiscDetection> {
        if (detections.size < windowSize) return detections

        val sorted = detections.sortedBy { it.frameIndex }
        val smoothed = ArrayList<DiscDetection>(sorted.size)
        val halfWindow = windowSize / 2

        for (i in sorted.indices) {
            var sumX = 0.0
            var sumY = 0.0
            var sumW = 0.0
            var sumH = 0.0
            var count = 0

            for (j in max(0, i - halfWindow)..min(sorted.size - 1, i + halfWindow)) {
                sumX += sorted[j].x
                sumY += sorted[j].y
                sumW += sorted[j].width
                sumH += sorted[j].height
                count++
            }

            smoothed += sorted[i].copy(
                x = sumX / count,
                y = sumY / count,
                width = sumW / count,
                height = sumH / count,
            )
        }

        return smoothed
    }

    /**
     * Fill gaps in detections using linear interpolation.
     *
     * Interpolated points carry a confidence of -1 so everything downstream can
     * tell a detected position from an invented one.
     */
    fun interpolateDetections(
        detections: List<DiscDetection>,
        fps: Double,
    ): List<DiscDetection> {
        if (detections.size < 2) return detections

        val sorted = detections.sortedBy { it.frameIndex }
        val result = ArrayList<DiscDetection>(sorted.size)

        for (i in 0 until sorted.size - 1) {
            val start = sorted[i]
            val end = sorted[i + 1]
            result += start

            val gap = end.frameIndex - start.frameIndex
            if (gap > 1 && gap <= MAX_INTERPOLATION_GAP) {
                for (f in 1 until gap) {
                    val t = f.toDouble() / gap
                    result += DiscDetection(
                        frameIndex = start.frameIndex + f,
                        x = start.x + (end.x - start.x) * t,
                        y = start.y + (end.y - start.y) * t,
                        width = start.width + (end.width - start.width) * t,
                        height = start.height + (end.height - start.height) * t,
                        confidence = -1.0,
                        timestampMs = DiscDetection.timestampFor(start.frameIndex + f, fps),
                    )
                }
            }
        }

        result += sorted.last()
        return result
    }
}

/**
 * Mutable lock-on state for the track-by-detection state machine: the disc's
 * last confirmed position, its estimated per-frame velocity, and how long it
 * has been coasting without a confirmed detection.
 */
class DiscTrack(
    var x: Double,
    var y: Double,
    var lastFrameIndex: Int,
) {
    var vx: Double = 0.0
        private set
    var vy: Double = 0.0
        private set
    var occlusionStreak: Int = 0

    /**
     * Linearly extrapolate the position [frameGap] frames ahead of the last
     * confirmed detection.
     */
    fun predict(frameGap: Int): Pair<Double, Double> = Pair(
        (x + vx * frameGap).coerceIn(0.0, 1.0),
        (y + vy * frameGap).coerceIn(0.0, 1.0),
    )

    /**
     * Fold a newly confirmed detection into the track: updates the position,
     * smooths the velocity estimate, and resets the occlusion counter.
     */
    fun confirm(detection: DiscDetection) {
        val gap = detection.frameIndex - lastFrameIndex
        if (gap > 0) {
            val newVx = (detection.x - x) / gap
            val newVy = (detection.y - y) / gap
            val smoothing = Trajectory.VELOCITY_SMOOTHING
            vx = smoothing * newVx + (1 - smoothing) * vx
            vy = smoothing * newVy + (1 - smoothing) * vy
        }
        x = detection.x
        y = detection.y
        lastFrameIndex = detection.frameIndex
        occlusionStreak = 0
    }
}
