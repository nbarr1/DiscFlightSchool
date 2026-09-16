package com.discflightschool.core.tracking

import com.discflightschool.core.detection.DiscDetection
import com.discflightschool.core.geometry.Vec2
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin

/**
 * Two fixed background reference points recorded at one video frame.
 *
 * Two points per frame is the minimum that pins down a full 2-D similarity
 * transform — translation, rotation, and uniform scale. One point would only
 * give translation, which cannot compensate for a camera that pans *and* zooms
 * while following the disc.
 */
data class WorldAnchorFrame(
    val frameIndex: Int,
    /** Normalized 0-1. */
    val pointA: Vec2,
    /** Normalized 0-1. */
    val pointB: Vec2,
)

/** A 2-D similarity transform: uniform scale, rotation, and translation. */
data class SimilarityTransform(
    val scale: Double,
    /** Radians. */
    val rotation: Double,
    /** Normalized units. */
    val translation: Vec2,
) {
    /** Apply the transform to a normalized point, in [size] pixel space. */
    fun apply(point: Vec2, width: Double, height: Double): Vec2 {
        val cosR = cos(rotation)
        val sinR = sin(rotation)
        val x = scale * (cosR * point.x - sinR * point.y) + translation.x
        val y = scale * (sinR * point.x + cosR * point.y) + translation.y
        return Vec2(x * width, y * height)
    }

    /** Undo the transform, returning a normalized point. */
    fun inverse(point: Vec2): Vec2 {
        val tx = point.x - translation.x
        val ty = point.y - translation.y
        val cosR = cos(-rotation)
        val sinR = sin(-rotation)
        return Vec2(
            (cosR * tx - sinR * ty) / scale,
            (sinR * tx + cosR * ty) / scale,
        )
    }

    companion object {
        val IDENTITY = SimilarityTransform(scale = 1.0, rotation = 0.0, translation = Vec2.ZERO)

        /** The transform mapping the pair (a1, b1) onto (a2, b2). */
        fun fromTwoPointPairs(a1: Vec2, b1: Vec2, a2: Vec2, b2: Vec2): SimilarityTransform {
            val d1 = (b1 - a1).distance
            val d2 = (b2 - a2).distance
            if (d1 < 1e-6) return IDENTITY

            val scale = d2 / d1
            val angle1 = atan2(b1.y - a1.y, b1.x - a1.x)
            val angle2 = atan2(b2.y - a2.y, b2.x - a2.x)
            val rotation = angle2 - angle1

            val c1 = Vec2((a1.x + b1.x) / 2, (a1.y + b1.y) / 2)
            val c2 = Vec2((a2.x + b2.x) / 2, (a2.y + b2.y) / 2)
            val cosR = cos(rotation)
            val sinR = sin(rotation)
            val rotated = Vec2(
                scale * (cosR * c1.x - sinR * c1.y),
                scale * (sinR * c1.x + cosR * c1.y),
            )

            return SimilarityTransform(
                scale = scale,
                rotation = rotation,
                translation = c2 - rotated,
            )
        }

        fun lerp(a: SimilarityTransform, b: SimilarityTransform, t: Double) = SimilarityTransform(
            scale = a.scale + (b.scale - a.scale) * t,
            rotation = a.rotation + (b.rotation - a.rotation) * t,
            translation = Vec2(
                a.translation.x + (b.translation.x - a.translation.x) * t,
                a.translation.y + (b.translation.y - a.translation.y) * t,
            ),
        )
    }
}

/**
 * Keeps a flight path pinned to the scene while the camera moves.
 *
 * Without this, a trail drawn in frame coordinates slides across the ground
 * whenever the camera pans to follow the disc — the path looks wrong precisely
 * on the throws that are most worth watching.
 */
object WorldLock {

    /**
     * The transform from the first anchor frame's view of the scene to the
     * view at [frame], interpolated between the surrounding anchors.
     *
     * Returns the identity when fewer than two anchor frames exist, which is
     * the un-locked case: positions are used exactly as recorded.
     */
    fun transformAt(frame: Int, anchors: List<WorldAnchorFrame>): SimilarityTransform {
        if (anchors.size < 2) return SimilarityTransform.IDENTITY

        val sorted = anchors.sortedBy { it.frameIndex }
        val base = sorted.first()
        if (frame <= base.frameIndex) return SimilarityTransform.IDENTITY

        val previous = sorted.lastOrNull { it.frameIndex <= frame } ?: base
        val next = sorted.firstOrNull { it.frameIndex >= frame } ?: sorted.last()

        val toPrevious = SimilarityTransform.fromTwoPointPairs(
            base.pointA,
            base.pointB,
            previous.pointA,
            previous.pointB,
        )
        if (previous.frameIndex == next.frameIndex) return toPrevious

        val toNext = SimilarityTransform.fromTwoPointPairs(
            base.pointA,
            base.pointB,
            next.pointA,
            next.pointB,
        )
        val t = (frame - previous.frameIndex).toDouble() /
            (next.frameIndex - previous.frameIndex)
        return SimilarityTransform.lerp(toPrevious, toNext, t.coerceIn(0.0, 1.0))
    }

    /**
     * Where a detection recorded at its own frame should be drawn when the
     * clip is showing [currentFrame], in pixels.
     */
    fun toCanvas(
        detection: DiscDetection,
        currentFrame: Int,
        width: Double,
        height: Double,
        anchors: List<WorldAnchorFrame> = emptyList(),
    ): Vec2 {
        if (anchors.size < 2) return Vec2(detection.x * width, detection.y * height)

        val recorded = transformAt(detection.frameIndex, anchors)
        val current = transformAt(currentFrame, anchors)
        val world = recorded.inverse(Vec2(detection.x, detection.y))
        return current.apply(world, width, height)
    }
}
