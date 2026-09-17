package com.discflightschool.app.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import com.discflightschool.app.ui.theme.AppColors
import com.discflightschool.core.posture.PostureMath
import kotlin.math.roundToInt

/** A pro reference angle plotted on the waveform, at the frame it was measured. */
data class PhaseMarker(
    /** Position along the clip, 0-1. */
    val t: Double,
    val angle: Double,
    val label: String,
)

/**
 * One joint angle across the whole throw, with the current frame marked.
 *
 * The track is smoothed before drawing: raw per-frame landmark noise makes a
 * plot that looks like a seismograph, and the shape of the motion is the point.
 * Tapping or dragging scrubs the video to that frame.
 */
@Composable
fun AngleWaveform(
    angleData: List<Double>,
    currentFrame: Int,
    modifier: Modifier = Modifier,
    phaseMarkers: List<PhaseMarker> = emptyList(),
    onSeekToFraction: ((Double) -> Unit)? = null,
) {
    val smoothed = remember(angleData) { smooth(angleData) }

    Canvas(
        modifier = modifier.then(
            if (onSeekToFraction == null) {
                Modifier
            } else {
                Modifier
                    .pointerInput(angleData) {
                        detectTapGestures { offset ->
                            onSeekToFraction((offset.x / size.width).toDouble().coerceIn(0.0, 1.0))
                        }
                    }
                    .pointerInput(angleData) {
                        detectHorizontalDragGestures { change, _ ->
                            onSeekToFraction(
                                (change.position.x / size.width).toDouble().coerceIn(0.0, 1.0),
                            )
                        }
                    }
            },
        ),
    ) {
        if (smoothed.isEmpty()) return@Canvas

        var minAngle = smoothed.min()
        var maxAngle = smoothed.max()
        for (marker in phaseMarkers) {
            if (marker.angle < minAngle) minAngle = marker.angle - 5
            if (marker.angle > maxAngle) maxAngle = marker.angle + 5
        }
        val range = maxAngle - minAngle
        if (range == 0.0) return@Canvas

        fun xFor(index: Int) =
            if (smoothed.size == 1) 0f else (index.toFloat() / (smoothed.size - 1)) * size.width

        fun yFor(value: Double) =
            size.height - ((value - minAngle) / range).toFloat() * size.height

        // Grid first, so the trace sits on top of it.
        for (i in 0..4) {
            val y = (i / 4f) * size.height
            drawLine(
                color = AppColors.Muted.copy(alpha = 0.3f),
                start = Offset(0f, y),
                end = Offset(size.width, y),
                strokeWidth = 1f,
            )
        }

        val trace = Path()
        val fill = Path()
        smoothed.forEachIndexed { index, value ->
            val x = xFor(index)
            val y = yFor(value)
            if (index == 0) {
                trace.moveTo(x, y)
                fill.moveTo(x, size.height)
                fill.lineTo(x, y)
            } else {
                trace.lineTo(x, y)
                fill.lineTo(x, y)
            }
        }
        fill.lineTo(size.width, size.height)
        fill.close()

        drawPath(fill, AppColors.FlightTracker.copy(alpha = 0.2f))
        drawPath(trace, AppColors.FlightTracker, style = Stroke(width = 2.dp.toPx()))

        val frameX = xFor(currentFrame.coerceIn(0, smoothed.size - 1))
        drawLine(
            color = AppColors.Bad,
            start = Offset(frameX, 0f),
            end = Offset(frameX, size.height),
            strokeWidth = 2.dp.toPx(),
        )

        if (phaseMarkers.isNotEmpty()) {
            val labelPaint = android.graphics.Paint().apply {
                color = AppColors.Good.toArgb()
                textSize = 9.dp.toPx()
                isAntiAlias = true
                typeface = android.graphics.Typeface.DEFAULT_BOLD
            }

            for (marker in phaseMarkers) {
                val markerX = (marker.t * size.width).toFloat()
                val markerY = yFor(marker.angle)

                drawCircle(AppColors.Good, radius = 5.dp.toPx(), center = Offset(markerX, markerY))
                drawCircle(
                    Color.White,
                    radius = 5.dp.toPx(),
                    center = Offset(markerX, markerY),
                    style = Stroke(width = 1.5f),
                )

                val labelWidth = labelPaint.measureText(marker.label)
                val labelX = (markerX - labelWidth / 2).coerceIn(0f, size.width - labelWidth)
                val labelY = (markerY + 16f).coerceAtMost(size.height - 2f)
                drawContext.canvas.nativeCanvas.drawText(marker.label, labelX, labelY, labelPaint)
            }
        }
    }
}

/** A median pass to drop single-frame glitches, then two averaging passes. */
private fun smooth(data: List<Double>): List<Double> {
    if (data.size < 3) return data
    var result = PostureMath.sparseMedianFilter(data, 3)
    result = PostureMath.sparseMovingAverage(result, 9)
    return PostureMath.sparseMovingAverage(result, 7)
}

/** The frame a 0-1 position along the waveform refers to. */
fun frameForFraction(fraction: Double, frameCount: Int): Int =
    if (frameCount <= 1) 0 else (fraction * (frameCount - 1)).roundToInt().coerceIn(0, frameCount - 1)
