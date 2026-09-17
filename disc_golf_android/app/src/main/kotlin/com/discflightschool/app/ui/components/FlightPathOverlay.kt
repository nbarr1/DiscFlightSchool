package com.discflightschool.app.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import com.discflightschool.core.detection.FlightTrackingResult
import com.discflightschool.core.geometry.Vec2
import com.discflightschool.core.tracking.WorldAnchorFrame
import com.discflightschool.core.tracking.WorldLock

/**
 * The flight trail drawn over the video.
 *
 * The trail is a midpoint quadratic curve through the detections rather than a
 * polyline: at 10fps a straight-segment path visibly kinks at every sample,
 * which reads as bad tracking even when the positions are right. A wide blurred
 * pass underneath the sharp one gives it the broadcast-graphic glow.
 *
 * With two or more anchor frames the points are world-locked first, so the path
 * stays put on the ground while the camera pans.
 */
@Composable
fun FlightPathOverlay(
    result: FlightTrackingResult,
    currentFrame: Int,
    modifier: Modifier = Modifier,
    showTrail: Boolean = true,
    showCurrentDisc: Boolean = true,
    showFullTrail: Boolean = false,
    anchors: List<WorldAnchorFrame> = emptyList(),
    targetLine: Pair<Vec2, Vec2>? = null,
    keyframeMarkers: List<Vec2> = emptyList(),
    pendingPoint: Vec2? = null,
) {
    Canvas(modifier) {
        drawFlightPath(
            result = result,
            currentFrame = currentFrame,
            showTrail = showTrail,
            showCurrentDisc = showCurrentDisc,
            showFullTrail = showFullTrail,
            anchors = anchors,
        )

        targetLine?.let { (start, end) -> drawTargetLine(start, end) }

        for (marker in keyframeMarkers) {
            drawKeyframeMarker(marker)
        }

        pendingPoint?.let { drawPendingPoint(it) }
    }
}

fun DrawScope.drawFlightPath(
    result: FlightTrackingResult,
    currentFrame: Int,
    showTrail: Boolean = true,
    showCurrentDisc: Boolean = true,
    showFullTrail: Boolean = false,
    anchors: List<WorldAnchorFrame> = emptyList(),
) {
    val detections = if (showFullTrail) {
        result.detections
    } else {
        result.detectionsUpToFrame(currentFrame)
    }
    if (detections.isEmpty()) return

    val points = detections.map { detection ->
        val position = WorldLock.toCanvas(
            detection = detection,
            currentFrame = currentFrame,
            width = size.width.toDouble(),
            height = size.height.toDouble(),
            anchors = anchors,
        )
        Offset(position.x.toFloat(), position.y.toFloat())
    }

    if (showTrail && points.size >= 2) {
        val path = Path().apply {
            moveTo(points[0].x, points[0].y)
            for (i in 0 until points.size - 1) {
                val midpoint = Offset(
                    (points[i].x + points[i + 1].x) / 2,
                    (points[i].y + points[i + 1].y) / 2,
                )
                quadraticTo(points[i].x, points[i].y, midpoint.x, midpoint.y)
            }
            lineTo(points.last().x, points.last().y)
        }

        val gradient = Brush.linearGradient(
            colors = listOf(TRAIL_START, TRAIL_MIDDLE, TRAIL_END),
            start = points.first(),
            end = points.last(),
        )

        // Glow pass.
        drawPath(
            path = path,
            brush = gradient,
            alpha = 0.22f,
            style = Stroke(
                width = 14.dp.toPx(),
                cap = StrokeCap.Round,
                join = StrokeJoin.Round,
            ),
        )
        // Sharp pass.
        drawPath(
            path = path,
            brush = gradient,
            alpha = 0.9f,
            style = Stroke(
                width = 3.dp.toPx(),
                cap = StrokeCap.Round,
                join = StrokeJoin.Round,
            ),
        )
    }

    if (showCurrentDisc) {
        val detection = result.detectionAtFrame(currentFrame) ?: return
        val center = Offset(detection.x.toFloat() * size.width, detection.y.toFloat() * size.height)
        drawCircle(Color.White.copy(alpha = 0.12f), radius = 16.dp.toPx(), center = center)
        drawCircle(
            Color.White,
            radius = 8.dp.toPx(),
            center = center,
            style = Stroke(width = 2.dp.toPx()),
        )
        drawCircle(Color.White, radius = 3.dp.toPx(), center = center)
    }
}

/** The reference line the user draws for throw direction. */
fun DrawScope.drawTargetLine(start: Vec2, end: Vec2) {
    val from = Offset(start.x.toFloat() * size.width, start.y.toFloat() * size.height)
    val to = Offset(end.x.toFloat() * size.width, end.y.toFloat() * size.height)

    drawLine(
        color = Color.Cyan.copy(alpha = 0.9f),
        start = from,
        end = to,
        strokeWidth = 2.dp.toPx(),
        pathEffect = PathEffect.dashPathEffect(floatArrayOf(12f, 8f)),
    )
    drawCircle(Color.Cyan, radius = 4.dp.toPx(), center = from)
    drawCircle(Color.Cyan, radius = 4.dp.toPx(), center = to)
}

/** A point the user has marked the disc at. */
fun DrawScope.drawKeyframeMarker(point: Vec2) {
    val center = Offset(point.x.toFloat() * size.width, point.y.toFloat() * size.height)
    drawCircle(Color.Yellow.copy(alpha = 0.3f), radius = 10.dp.toPx(), center = center)
    drawCircle(
        Color.Yellow,
        radius = 6.dp.toPx(),
        center = center,
        style = Stroke(width = 2.dp.toPx()),
    )
}

/** The first corner of a bounding box, waiting for its second tap. */
fun DrawScope.drawPendingPoint(point: Vec2) {
    val center = Offset(point.x.toFloat() * size.width, point.y.toFloat() * size.height)
    drawCircle(
        Color.Magenta,
        radius = 8.dp.toPx(),
        center = center,
        style = Stroke(width = 2.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(6f, 4f))),
    )
    drawLine(
        Color.Magenta,
        start = Offset(center.x - 14f, center.y),
        end = Offset(center.x + 14f, center.y),
        strokeWidth = 1.5f,
        blendMode = BlendMode.SrcOver,
    )
    drawLine(
        Color.Magenta,
        start = Offset(center.x, center.y - 14f),
        end = Offset(center.x, center.y + 14f),
        strokeWidth = 1.5f,
    )
}

// Green through red along the flight, so the direction of travel reads at a
// glance on a still frame.
private val TRAIL_START = Color(0xFF1AF01A)
private val TRAIL_MIDDLE = Color(0xFFF0F01A)
private val TRAIL_END = Color(0xFFF01A1A)
