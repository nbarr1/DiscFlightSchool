package com.discflightschool.app.pose

import android.graphics.BitmapFactory
import android.util.Log
import com.discflightschool.app.video.FrameExtractor
import com.discflightschool.core.geometry.Vec2
import com.discflightschool.core.geometry.Vec3
import com.discflightschool.core.math.AngleCalculator
import com.discflightschool.core.model.FormAnalysis
import com.discflightschool.core.model.FormFrame
import com.discflightschool.core.model.ThrowTypes
import com.discflightschool.core.posture.LANDMARK_CONFIDENCE_THRESHOLD
import com.discflightschool.core.posture.PostureMath
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.pose.Pose
import com.google.mlkit.vision.pose.PoseDetection
import com.google.mlkit.vision.pose.PoseLandmark
import com.google.mlkit.vision.pose.accurate.AccuratePoseDetectorOptions
import java.io.File
import java.time.Instant
import kotlin.math.abs
import kotlin.math.atan2
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Measures joint angles across a throw using ML Kit pose detection.
 *
 * Angles are computed in 3-D whenever the detector reports usable depth, and
 * fall back to the image-plane calculation when it does not. A landmark below
 * [LANDMARK_CONFIDENCE_THRESHOLD] is dropped rather than used: a guessed
 * landmark produces a confident-looking angle that is simply wrong.
 */
class PostureAnalyzer(private val frameExtractor: FrameExtractor) {

    private val detector by lazy {
        PoseDetection.getClient(
            AccuratePoseDetectorOptions.Builder()
                .setDetectorMode(AccuratePoseDetectorOptions.SINGLE_IMAGE_MODE)
                .build(),
        )
    }

    /**
     * Analyse [frameCount] frames of [videoPath] starting at [startMs].
     *
     * Always returns an analysis, even when nothing could be measured: the
     * screen still has something to render, and [FormAnalysis.failureReason]
     * says why the numbers are synthesized rather than presenting them as a
     * measurement.
     */
    suspend fun analyzeForm(
        videoPath: String,
        cacheDir: File,
        startMs: Long = 0,
        frameCount: Int = 30,
        isLeftHanded: Boolean = false,
        throwType: String = ThrowTypes.BACKHAND,
        onProgress: ((Float) -> Unit)? = null,
    ): FormAnalysis = withContext(Dispatchers.Default) {
        val framesDir = File(cacheDir, "pose_${System.currentTimeMillis()}")
        try {
            val extracted = frameExtractor.extractFrames(
                videoPath = videoPath,
                outputDir = framesDir,
                fps = 1000.0 / FrameExtractor.POSE_INTERVAL_MS,
                maxFrames = frameCount,
                startMs = startMs,
            )

            if (extracted.isEmpty()) {
                return@withContext mockAnalysis(
                    videoPath,
                    "No frames could be extracted from this video. Check that the clip is a " +
                        "supported format and long enough to analyse.",
                )
            }

            var imageWidth: Double? = null
            var imageHeight: Double? = null
            val frames = ArrayList<FormFrame>(extracted.size)

            for ((i, frame) in extracted.withIndex()) {
                onProgress?.invoke((i + 1).toFloat() / extracted.size)

                val bitmap = runCatching { BitmapFactory.decodeFile(frame.path) }.getOrNull()
                if (bitmap == null) {
                    frames += FormFrame(
                        timestampMs = i * FrameExtractor.POSE_INTERVAL_MS,
                        imageWidth = imageWidth,
                        imageHeight = imageHeight,
                    )
                    continue
                }

                if (imageWidth == null) {
                    imageWidth = bitmap.width.toDouble()
                    imageHeight = bitmap.height.toDouble()
                }

                val pose = runCatching {
                    Tasks.await(detector.process(InputImage.fromBitmap(bitmap, 0)))
                }.getOrElse {
                    Log.w(TAG, "Pose detection failed on frame ${frame.index}", it)
                    null
                }
                bitmap.recycle()

                val landmarks = pose?.allPoseLandmarks.orEmpty()
                if (pose == null || landmarks.isEmpty()) {
                    frames += FormFrame(
                        timestampMs = i * FrameExtractor.POSE_INTERVAL_MS,
                        imageWidth = imageWidth,
                        imageHeight = imageHeight,
                    )
                    continue
                }

                val confidence = pose.confidenceByName()
                val depth = pose.depthByName()
                val keyPoints = pose.pointsByName()
                val raw = angles3D(pose, confidence) ?: angles2D(pose, confidence)
                val oriented = if (isLeftHanded) PostureMath.mirrorAngles(raw) else raw

                frames += FormFrame(
                    timestampMs = i * FrameExtractor.POSE_INTERVAL_MS,
                    angles = PostureMath.clampToPhysiologicalLimits(oriented),
                    keyPoints = keyPoints.toMutableMap(),
                    landmarkZ = depth,
                    landmarkConf = confidence,
                    imageWidth = imageWidth,
                    imageHeight = imageHeight,
                )
            }

            // Frames exist but no pose was found in any of them — the thrower is
            // probably out of frame, too small, or the light is too poor. That
            // is a real result, not a crash, but it must not be scored.
            if (frames.all { it.keyPoints.isEmpty() }) {
                return@withContext mockAnalysis(
                    videoPath,
                    "No body pose was detected in any frame. Record with your whole body in " +
                        "frame, in good light, and try again.",
                )
            }

            PostureMath.smoothFrameAngles(frames)
            PostureMath.smoothKeyPoints(frames)

            FormAnalysis(
                id = System.currentTimeMillis().toString(),
                date = Instant.now(),
                videoPath = videoPath,
                frames = frames,
                score = 0.0,
            )
        } catch (e: Exception) {
            Log.e(TAG, "Form analysis failed", e)
            mockAnalysis(videoPath, "Analysis failed: ${e.message ?: e::class.java.simpleName}")
        } finally {
            runCatching { framesDir.deleteRecursively() }
        }
    }

    /** Recompute a frame's angles after the user has moved its landmarks. */
    fun recalculateFrameAngles(frame: FormFrame) {
        val recalculated = AngleCalculator.calculateFromKeyPoints(frame.keyPoints)
        frame.angles.clear()
        frame.angles.putAll(recalculated)
    }

    fun close() {
        runCatching { detector.close() }
    }

    // ── Angle calculation ────────────────────────────────────────────────

    private fun angles2D(pose: Pose, confidence: Map<String, Double>): MutableMap<String, Double> {
        val angles = LinkedHashMap<String, Double>()

        fun trusted(type: Int): Vec2? {
            val landmark = pose.getPoseLandmark(type) ?: return null
            val name = LANDMARK_NAMES[type] ?: return null
            if ((confidence[name] ?: 0.0) < LANDMARK_CONFIDENCE_THRESHOLD) return null
            return Vec2(landmark.position.x.toDouble(), landmark.position.y.toDouble())
        }

        fun set(key: String, a: Vec2?, b: Vec2?, c: Vec2?) {
            if (a == null || b == null || c == null) return
            val value = AngleCalculator.angleBetween(a, b, c)
            if (!value.isNaN()) angles[key] = value
        }

        val rShoulder = trusted(PoseLandmark.RIGHT_SHOULDER)
        val lShoulder = trusted(PoseLandmark.LEFT_SHOULDER)
        val rHip = trusted(PoseLandmark.RIGHT_HIP)
        val lHip = trusted(PoseLandmark.LEFT_HIP)

        set("rightElbowAngle", rShoulder, trusted(PoseLandmark.RIGHT_ELBOW), trusted(PoseLandmark.RIGHT_WRIST))
        set("leftElbowAngle", lShoulder, trusted(PoseLandmark.LEFT_ELBOW), trusted(PoseLandmark.LEFT_WRIST))
        set("rightShoulderAngle", trusted(PoseLandmark.RIGHT_ELBOW), rShoulder, rHip)
        set("leftShoulderAngle", trusted(PoseLandmark.LEFT_ELBOW), lShoulder, lHip)
        set("rightKneeAngle", rHip, trusted(PoseLandmark.RIGHT_KNEE), trusted(PoseLandmark.RIGHT_ANKLE))
        set("leftKneeAngle", lHip, trusted(PoseLandmark.LEFT_KNEE), trusted(PoseLandmark.LEFT_ANKLE))

        spineAngle(rShoulder, lShoulder, rHip, lHip)?.let { angles["spineAngle"] = it }

        return angles
    }

    /**
     * The 3-D angles, or null when the detector reported no usable depth.
     *
     * ML Kit returns z values on the same scale as x; a clip shot dead-on can
     * come back with every z at zero, in which case the 2-D calculation is the
     * honest one.
     */
    private fun angles3D(pose: Pose, confidence: Map<String, Double>): MutableMap<String, Double>? {
        val maxAbsZ = pose.allPoseLandmarks.maxOfOrNull { abs(it.position3D.z) } ?: 0f
        if (maxAbsZ < MIN_USABLE_DEPTH) return null

        fun trusted(type: Int): Vec3? {
            val landmark = pose.getPoseLandmark(type) ?: return null
            val name = LANDMARK_NAMES[type] ?: return null
            if ((confidence[name] ?: 0.0) < LANDMARK_CONFIDENCE_THRESHOLD) return null
            return Vec3(
                landmark.position3D.x.toDouble(),
                landmark.position3D.y.toDouble(),
                landmark.position3D.z.toDouble(),
            )
        }

        val angles = LinkedHashMap<String, Double>()

        fun set(key: String, a: Vec3?, b: Vec3?, c: Vec3?) {
            if (a == null || b == null || c == null) return
            val value = AngleCalculator.angleBetween3D(a, b, c)
            if (!value.isNaN()) angles[key] = value
        }

        val rShoulder = trusted(PoseLandmark.RIGHT_SHOULDER)
        val lShoulder = trusted(PoseLandmark.LEFT_SHOULDER)
        val rHip = trusted(PoseLandmark.RIGHT_HIP)
        val lHip = trusted(PoseLandmark.LEFT_HIP)

        set("rightElbowAngle", rShoulder, trusted(PoseLandmark.RIGHT_ELBOW), trusted(PoseLandmark.RIGHT_WRIST))
        set("leftElbowAngle", lShoulder, trusted(PoseLandmark.LEFT_ELBOW), trusted(PoseLandmark.LEFT_WRIST))
        set("rightShoulderAngle", trusted(PoseLandmark.RIGHT_ELBOW), rShoulder, rHip)
        set("leftShoulderAngle", trusted(PoseLandmark.LEFT_ELBOW), lShoulder, lHip)
        set("rightKneeAngle", rHip, trusted(PoseLandmark.RIGHT_KNEE), trusted(PoseLandmark.RIGHT_ANKLE))
        set("leftKneeAngle", lHip, trusted(PoseLandmark.LEFT_KNEE), trusted(PoseLandmark.LEFT_ANKLE))

        if (rShoulder != null && lShoulder != null && rHip != null && lHip != null) {
            val xFactor = AngleCalculator.xFactor3D(rShoulder, lShoulder, rHip, lHip)
            if (!xFactor.isNaN()) angles["xFactor"] = xFactor

            spineAngle(
                Vec2(rShoulder.x, rShoulder.y),
                Vec2(lShoulder.x, lShoulder.y),
                Vec2(rHip.x, rHip.y),
                Vec2(lHip.x, lHip.y),
            )?.let { angles["spineAngle"] = it }
        }

        return angles.ifEmpty { null }
    }

    /** Trunk lean from the shoulder and hip midpoints: 90 degrees is upright. */
    private fun spineAngle(
        rightShoulder: Vec2?,
        leftShoulder: Vec2?,
        rightHip: Vec2?,
        leftHip: Vec2?,
    ): Double? {
        if (rightShoulder == null || leftShoulder == null || rightHip == null || leftHip == null) {
            return null
        }
        val shoulderMidX = (rightShoulder.x + leftShoulder.x) / 2
        val shoulderMidY = (rightShoulder.y + leftShoulder.y) / 2
        val hipMidX = (rightHip.x + leftHip.x) / 2
        val hipMidY = (rightHip.y + leftHip.y) / 2
        val spine = atan2(shoulderMidX - hipMidX, hipMidY - shoulderMidY) * (180.0 / Math.PI)
        return 90 - abs(spine)
    }

    private fun mockAnalysis(videoPath: String, failureReason: String): FormAnalysis {
        val frames = (0 until 30).map { index ->
            FormFrame(
                timestampMs = index * 100L,
                angles = PostureMath.mockAngles(index / 30.0),
            )
        }
        return FormAnalysis(
            id = System.currentTimeMillis().toString(),
            date = Instant.now(),
            videoPath = videoPath,
            frames = frames,
            score = 0.0,
            isMock = true,
            failureReason = failureReason,
        )
    }

    private fun Pose.pointsByName(): Map<String, Vec2> = allPoseLandmarks.mapNotNull { landmark ->
        LANDMARK_NAMES[landmark.landmarkType]?.let { name ->
            name to Vec2(landmark.position.x.toDouble(), landmark.position.y.toDouble())
        }
    }.toMap()

    private fun Pose.confidenceByName(): Map<String, Double> =
        allPoseLandmarks.mapNotNull { landmark ->
            LANDMARK_NAMES[landmark.landmarkType]?.let { it to landmark.inFrameLikelihood.toDouble() }
        }.toMap()

    private fun Pose.depthByName(): Map<String, Double> =
        allPoseLandmarks.mapNotNull { landmark ->
            LANDMARK_NAMES[landmark.landmarkType]?.let { it to landmark.position3D.z.toDouble() }
        }.toMap()

    companion object {
        private const val TAG = "PostureAnalyzer"

        /** Below this, every landmark's depth is effectively zero. */
        private const val MIN_USABLE_DEPTH = 0.01f

        /**
         * Landmark names, kept in the format earlier versions persisted so a
         * user's saved sessions and hand-corrected frames keep loading.
         */
        val LANDMARK_NAMES: Map<Int, String> = mapOf(
            PoseLandmark.NOSE to "PoseLandmarkType.nose",
            PoseLandmark.LEFT_EYE_INNER to "PoseLandmarkType.leftEyeInner",
            PoseLandmark.LEFT_EYE to "PoseLandmarkType.leftEye",
            PoseLandmark.LEFT_EYE_OUTER to "PoseLandmarkType.leftEyeOuter",
            PoseLandmark.RIGHT_EYE_INNER to "PoseLandmarkType.rightEyeInner",
            PoseLandmark.RIGHT_EYE to "PoseLandmarkType.rightEye",
            PoseLandmark.RIGHT_EYE_OUTER to "PoseLandmarkType.rightEyeOuter",
            PoseLandmark.LEFT_EAR to "PoseLandmarkType.leftEar",
            PoseLandmark.RIGHT_EAR to "PoseLandmarkType.rightEar",
            PoseLandmark.LEFT_MOUTH to "PoseLandmarkType.leftMouth",
            PoseLandmark.RIGHT_MOUTH to "PoseLandmarkType.rightMouth",
            PoseLandmark.LEFT_SHOULDER to "PoseLandmarkType.leftShoulder",
            PoseLandmark.RIGHT_SHOULDER to "PoseLandmarkType.rightShoulder",
            PoseLandmark.LEFT_ELBOW to "PoseLandmarkType.leftElbow",
            PoseLandmark.RIGHT_ELBOW to "PoseLandmarkType.rightElbow",
            PoseLandmark.LEFT_WRIST to "PoseLandmarkType.leftWrist",
            PoseLandmark.RIGHT_WRIST to "PoseLandmarkType.rightWrist",
            PoseLandmark.LEFT_PINKY to "PoseLandmarkType.leftPinky",
            PoseLandmark.RIGHT_PINKY to "PoseLandmarkType.rightPinky",
            PoseLandmark.LEFT_INDEX to "PoseLandmarkType.leftIndex",
            PoseLandmark.RIGHT_INDEX to "PoseLandmarkType.rightIndex",
            PoseLandmark.LEFT_THUMB to "PoseLandmarkType.leftThumb",
            PoseLandmark.RIGHT_THUMB to "PoseLandmarkType.rightThumb",
            PoseLandmark.LEFT_HIP to "PoseLandmarkType.leftHip",
            PoseLandmark.RIGHT_HIP to "PoseLandmarkType.rightHip",
            PoseLandmark.LEFT_KNEE to "PoseLandmarkType.leftKnee",
            PoseLandmark.RIGHT_KNEE to "PoseLandmarkType.rightKnee",
            PoseLandmark.LEFT_ANKLE to "PoseLandmarkType.leftAnkle",
            PoseLandmark.RIGHT_ANKLE to "PoseLandmarkType.rightAnkle",
            PoseLandmark.LEFT_HEEL to "PoseLandmarkType.leftHeel",
            PoseLandmark.RIGHT_HEEL to "PoseLandmarkType.rightHeel",
            PoseLandmark.LEFT_FOOT_INDEX to "PoseLandmarkType.leftFootIndex",
            PoseLandmark.RIGHT_FOOT_INDEX to "PoseLandmarkType.rightFootIndex",
        )

        /** The bone pairs drawn by the skeleton overlay. */
        val SKELETON_BONES: List<Pair<String, String>> = listOf(
            "PoseLandmarkType.leftShoulder" to "PoseLandmarkType.rightShoulder",
            "PoseLandmarkType.leftShoulder" to "PoseLandmarkType.leftElbow",
            "PoseLandmarkType.leftElbow" to "PoseLandmarkType.leftWrist",
            "PoseLandmarkType.rightShoulder" to "PoseLandmarkType.rightElbow",
            "PoseLandmarkType.rightElbow" to "PoseLandmarkType.rightWrist",
            "PoseLandmarkType.leftShoulder" to "PoseLandmarkType.leftHip",
            "PoseLandmarkType.rightShoulder" to "PoseLandmarkType.rightHip",
            "PoseLandmarkType.leftHip" to "PoseLandmarkType.rightHip",
            "PoseLandmarkType.leftHip" to "PoseLandmarkType.leftKnee",
            "PoseLandmarkType.leftKnee" to "PoseLandmarkType.leftAnkle",
            "PoseLandmarkType.rightHip" to "PoseLandmarkType.rightKnee",
            "PoseLandmarkType.rightKnee" to "PoseLandmarkType.rightAnkle",
        )
    }
}
