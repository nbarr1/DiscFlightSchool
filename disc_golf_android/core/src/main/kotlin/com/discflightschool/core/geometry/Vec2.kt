package com.discflightschool.core.geometry

import kotlin.math.hypot

/**
 * A 2-D point or vector in normalized (0-1) or pixel space, whichever the
 * caller is working in.
 *
 * Double-precision rather than float: the angle and spline maths here is a
 * direct port of the Dart implementation, and matching its arithmetic exactly
 * keeps the ported tests meaningful.
 */
data class Vec2(val x: Double, val y: Double) {
    operator fun plus(other: Vec2): Vec2 = Vec2(x + other.x, y + other.y)

    operator fun minus(other: Vec2): Vec2 = Vec2(x - other.x, y - other.y)

    operator fun times(factor: Double): Vec2 = Vec2(x * factor, y * factor)

    val distance: Double get() = hypot(x, y)

    fun distanceTo(other: Vec2): Double = (this - other).distance

    companion object {
        val ZERO = Vec2(0.0, 0.0)
    }
}

/** A 3-D point, used for depth-aware angle calculations. */
data class Vec3(val x: Double, val y: Double, val z: Double)
