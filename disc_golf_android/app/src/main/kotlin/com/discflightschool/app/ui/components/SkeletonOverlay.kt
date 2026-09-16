package com.discflightschool.app.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.dp
import com.discflightschool.app.ui.theme.AppColors
import com.discflightschool.core.geometry.Vec2
import com.discflightschool.core.model.FormFrame
import kotlin.math.abs

/**
 * The pose skeleton drawn over a video frame.
 *
 * Limbs are coloured by how far their joint angle is from the disc golf ideal,
 * so a glance says which part of the throw is off. In correction mode the
 * adjustable joints are ringed by how much the detector trusted them — a
 * landmark it was unsure of is exactly the one worth dragging.
 */
object SkeletonOverlay {

    /** The 12 landmarks that can be adjusted by hand. */
    val ADJUSTABLE_LANDMARKS = listOf(
        "PoseLandmarkType.rightShoulder",
        "PoseLandmarkType.leftShoulder",
        "PoseLandmarkType.rightElbow",
        "PoseLandmarkType.leftElbow",
        "PoseLandmarkType.rightWrist",
        "PoseLandmarkType.leftWrist",
        "PoseLandmarkType.rightHip",
        "PoseLandmarkType.leftHip",
        "PoseLandmarkType.rightKnee",
        "PoseLandmarkType.leftKnee",
        "PoseLandmarkType.rightAnkle",
        "PoseLandmarkType.leftAnkle",
    )

    /** Target angles for a sound disc golf throw, in degrees. */
    private val IDEAL_ANGLES = mapOf(
        "rightElbowAngle" to 120.0,
        "leftElbowAngle" to 140.0,
        "rightShoulderAngle" to 100.0,
        "leftShoulderAngle" to 100.0,
        "rightKneeAngle" to 160.0,
        "leftKneeAngle" to 160.0,
        "spineAngle" to 85.0,
    )

    private data class LimbGroup(val bones: List<Pair<String, String>>, val angleKey: String)

    private val LIMB_GROUPS = listOf(
        LimbGroup(
            bones = listOf(
                "PoseLandmarkType.rightShoulder" to "PoseLandmarkType.rightElbow",
                "PoseLandmarkType.rightElbow" to "PoseLandmarkType.rightWrist",
            ),
            angleKey = "rightElbowAngle",
        ),
        LimbGroup(
            bones = listOf(
                "PoseLandmarkType.leftShoulder" to "PoseLandmarkType.leftElbow",
                "PoseLandmarkType.leftElbow" to "PoseLandmarkType.leftWrist",
            ),
            angleKey = "leftElbowAngle",
        ),
        LimbGroup(
            bones = listOf(
                "PoseLandmarkType.rightHip" to "PoseLandmarkType.rightKnee",
                "PoseLandmarkType.rightKnee" to "PoseLandmarkType.rightAnkle",
            ),
            angleKey = "rightKneeAngle",
        ),
        LimbGroup(
            bones = listOf(
                "PoseLandmarkType.leftHip" to "PoseLandmarkType.leftKnee",
                "PoseLandmarkType.leftKnee" to "PoseLandmarkType.leftAnkle",
            ),
            angleKey = "leftKneeAngle",
        ),
        LimbGroup(
            bones = listOf(
                "PoseLandmarkType.leftShoulder" to "PoseLandmarkType.rightShoulder",
                "PoseLandmarkType.leftShoulder" to "PoseLandmarkType.leftHip",
                "PoseLandmarkType.rightShoulder" to "PoseLandmarkType.rightHip",
                "PoseLandmarkType.leftHip" to "PoseLandmarkType.rightHip",
            ),
            angleKey = "spineAngle",
        ),
    )

    private data class AngleLabel(val vertexKey: String, val angleKey: String)

    /** Labels only on the throwing elbow, throwing shoulder, and lead knee. */
    private val ANGLE_LABELS = listOf(
        AngleLabel("PoseLandmarkType.rightElbow", "rightElbowAngle"),
        AngleLabel("PoseLandmarkType.rightShoulder", "rightShoulderAngle"),
        AngleLabel("PoseLandmarkType.rightKnee", "rightKneeAngle"),
    )

    /**
     * Map a landmark into canvas space.
     *
     * Landmarks arrive in whatever space the detector produced: pixels when the
     * frame's dimensions are known, normalized 0-1 for a hand-corrected frame,
     * and pixels against a 640-wide working frame when neither is recorded.
     */
    fun scalePoint(point: Vec2, canvasSize: Size, frame: FormFrame): Offset {
        val imageWidth = frame.imageWidth
        val imageHeight = frame.imageHeight

        if (imageWidth != null && imageHeight != null && imageWidth > 0 && imageHeight > 0) {
            return Offset(
                (point.x * canvasSize.width / imageWidth).toFloat(),
                (point.y * canvasSize.height / imageHeight).toFloat(),
            )
        }
        if (point.x <= 1.0 && point.y <= 1.0) {
            return Offset(
                (point.x * canvasSize.width).toFloat(),
                (point.y * canvasSize.height).toFloat(),
            )
        }
        return Offset(
            (point.x * canvasSize.width / 640).toFloat(),
            (point.y * canvasSize.height / 640).toFloat(),
        )
    }

    /** Convert canvas coordinates back into the frame's own space. */
    fun canvasToImage(canvasPoint: Offset, canvasSize: Size, frame: FormFrame): Vec2 {
        val imageWidth = frame.imageWidth
        val imageHeight = frame.imageHeight
        if (imageWidth != null && imageHeight != null && imageWidth > 0 && imageHeight > 0) {
            return Vec2(
                canvasPoint.x * imageWidth / canvasSize.width,
                canvasPoint.y * imageHeight / canvasSize.height,
            )
        }
        return Vec2(
            (canvasPoint.x / canvasSize.width).toDouble(),
            (canvasPoint.y / canvasSize.height).toDouble(),
        )
    }

    /**
     * The adjustable landmark nearest a tap, or null when nothing is within
     * [thresholdPx].
     */
    fun nearestLandmark(
        tapPoint: Offset,
        canvasSize: Size,
        frame: FormFrame,
        thresholdPx: Float = 60f,
    ): String? {
        var closest: String? = null
        var closestDistance = thresholdPx

        for (key in ADJUSTABLE_LANDMARKS) {
            val point = frame.keyPoints[key] ?: continue
            val distance = (scalePoint(point, canvasSize, frame) - tapPoint).getDistance()
            if (distance < closestDistance) {
                closestDistance = distance
                closest = key
            }
        }
        return closest
    }

    /** Green through red, by how far an angle sits from its ideal. */
    fun angleColor(angleKey: String, angle: Double?): Color {
        if (angle == null) return AppColors.Muted
        val ideal = IDEAL_ANGLES[angleKey] ?: return AppColors.Accent
        val difference = abs(angle - ideal)
        return when {
            difference < 10 -> AppColors.Good
            difference < 25 -> AppColors.Warning
            else -> AppColors.Bad
        }
    }

    /**
     * The ring colour for an adjustable joint, by detector confidence.
     *
     * A frame with no confidence data was corrected by hand, and a correction
     * the user made is the most trustworthy landmark on screen.
     */
    fun confidenceColor(key: String, confidence: Map<String, Double>): Color {
        if (confidence.isEmpty()) return AppColors.Accent
        val value = confidence[key] ?: return AppColors.Bad
        return when {
            value >= 0.7 -> AppColors.Accent
            value >= 0.5 -> AppColors.Warning
            else -> AppColors.Bad
        }
    }

    /** Draw the skeleton for [frame] across the whole draw scope. */
    fun DrawScope.drawSkeleton(
        frame: FormFrame,
        interactive: Boolean = false,
        selectedLandmark: String? = null,
    ) {
        if (frame.keyPoints.isEmpty()) return

        for (group in LIMB_GROUPS) {
            val color = angleColor(group.angleKey, frame.angles[group.angleKey])
            for ((startKey, endKey) in group.bones) {
                val start = frame.keyPoints[startKey] ?: continue
                val end = frame.keyPoints[endKey] ?: continue
                drawLine(
                    color = color.copy(alpha = 0.8f),
                    start = scalePoint(start, size, frame),
                    end = scalePoint(end, size, frame),
                    strokeWidth = 2.5.dp.toPx(),
                    cap = androidx.compose.ui.graphics.StrokeCap.Round,
                )
            }
        }

        for ((key, point) in frame.keyPoints) {
            val center = scalePoint(point, size, frame)
            if (interactive && key in ADJUSTABLE_LANDMARKS) {
                if (key == selectedLandmark) {
                    drawCircle(Color.Yellow.copy(alpha = 0.25f), radius = 12.dp.toPx(), center = center)
                    drawCircle(Color.Yellow, radius = 8.dp.toPx(), center = center)
                    drawCircle(
                        Color.Black,
                        radius = 8.dp.toPx(),
                        center = center,
                        style = Stroke(width = 2.dp.toPx()),
                    )
                } else {
                    drawCircle(Color.White, radius = 6.dp.toPx(), center = center)
                    drawCircle(
                        confidenceColor(key, frame.landmarkConf),
                        radius = 6.dp.toPx(),
                        center = center,
                        style = Stroke(width = 2.dp.toPx()),
                    )
                }
            } else {
                drawCircle(Color.White, radius = 3.5.dp.toPx(), center = center)
                drawCircle(
                    Color.Black.copy(alpha = 0.5f),
                    radius = 3.5.dp.toPx(),
                    center = center,
                    style = Stroke(width = 1.dp.toPx()),
                )
            }
        }

        drawAngleLabels(frame)
    }

    private fun DrawScope.drawAngleLabels(frame: FormFrame) {
        val textSize = 11.dp.toPx()

        for (label in ANGLE_LABELS) {
            val vertex = frame.keyPoints[label.vertexKey] ?: continue
            val angle = frame.angles[label.angleKey] ?: continue

            val position = scalePoint(vertex, size, frame) + Offset(10f, -14f)
            val color = angleColor(label.angleKey, angle)
            val text = "${angle.toInt()}°"

            val paint = android.graphics.Paint().apply {
                this.color = color.toArgb()
                this.textSize = textSize
                isAntiAlias = true
                typeface = android.graphics.Typeface.DEFAULT_BOLD
            }
            val textWidth = paint.measureText(text)

            drawRoundRect(
                color = Color.Black.copy(alpha = 0.7f),
                topLeft = Offset(position.x - 3f, position.y - textSize),
                size = Size(textWidth + 6f, textSize + 6f),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(4f, 4f),
            )

            drawContext.canvas.nativeCanvas.drawText(text, position.x, position.y, paint)
        }
    }
}

/** The skeleton for one frame, sized to fill its box. */
@Composable
fun SkeletonCanvas(
    frame: FormFrame,
    modifier: Modifier = Modifier,
    interactive: Boolean = false,
    selectedLandmark: String? = null,
) {
    Canvas(modifier) {
        with(SkeletonOverlay) {
            drawSkeleton(
                frame = frame,
                interactive = interactive,
                selectedLandmark = selectedLandmark,
            )
        }
    }
}
