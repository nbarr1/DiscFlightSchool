package com.discflightschool.core

import com.discflightschool.core.model.FormAnalysis
import com.discflightschool.core.model.FormFrame
import com.discflightschool.core.model.ThrowTypes
import com.discflightschool.core.posture.PostureMath
import java.time.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PostureMathTest {

    private fun frame(angles: Map<String, Double>, ms: Long = 0) =
        FormFrame(timestampMs = ms, angles = angles.toMutableMap())

    // ── kneeSideLabel ────────────────────────────────────────────────────

    @Test
    fun `backhand right knee is the lead leg`() {
        assertEquals("lead", PostureMath.kneeSideLabel("rightKneeAngle", ThrowTypes.BACKHAND))
        assertEquals("trail", PostureMath.kneeSideLabel("leftKneeAngle", ThrowTypes.BACKHAND))
    }

    @Test
    fun `forehand right knee is the trail leg`() {
        assertEquals("trail", PostureMath.kneeSideLabel("rightKneeAngle", ThrowTypes.FOREHAND))
        assertEquals("lead", PostureMath.kneeSideLabel("leftKneeAngle", ThrowTypes.FOREHAND))
    }

    @Test
    fun `the knee label always matches the pro-data key it is compared against`() {
        for (throwType in listOf(ThrowTypes.BACKHAND, ThrowTypes.FOREHAND)) {
            for (appKey in listOf("rightKneeAngle", "leftKneeAngle")) {
                val label = PostureMath.kneeSideLabel(appKey, throwType)
                assertEquals(
                    "$appKey/$throwType label disagrees with its data key",
                    "${label}_knee_flexion_deg",
                    PostureMath.reverseAngleKey(appKey, throwType),
                )
            }
        }
    }

    @Test
    fun `kneeSideLabel returns null for non-knee angles`() {
        assertNull(PostureMath.kneeSideLabel("rightElbowAngle", ThrowTypes.BACKHAND))
        assertNull(PostureMath.kneeSideLabel("spineAngle", ThrowTypes.FOREHAND))
        assertNull(PostureMath.kneeSideLabel("nonsense", ThrowTypes.BACKHAND))
    }

    // ── reverseAngleKey ──────────────────────────────────────────────────

    @Test
    fun `maps shared angles identically for both throw types`() {
        for (key in listOf(
            "rightElbowAngle",
            "rightShoulderAngle",
            "spineAngle",
            "leftElbowAngle",
            "leftShoulderAngle",
            "xFactor",
        )) {
            assertEquals(
                "$key should not depend on throw type",
                PostureMath.reverseAngleKey(key, ThrowTypes.BACKHAND),
                PostureMath.reverseAngleKey(key, ThrowTypes.FOREHAND),
            )
        }
    }

    @Test
    fun `mirrors only the knees between throw types`() {
        assertNotEquals(
            PostureMath.reverseAngleKey("rightKneeAngle", ThrowTypes.BACKHAND),
            PostureMath.reverseAngleKey("rightKneeAngle", ThrowTypes.FOREHAND),
        )
    }

    @Test
    fun `reverseAngleKey returns null for an unknown key`() {
        assertNull(PostureMath.reverseAngleKey("bogus", ThrowTypes.BACKHAND))
    }

    // ── clampToPhysiologicalLimits ───────────────────────────────────────

    @Test
    fun `leaves in-range angles untouched`() {
        val result = PostureMath.clampToPhysiologicalLimits(
            mapOf(
                "rightElbowAngle" to 95.0,
                "rightKneeAngle" to 150.0,
                "spineAngle" to 80.0,
            ),
        )
        assertEquals(95.0, result.getValue("rightElbowAngle"), 0.0)
        assertEquals(150.0, result.getValue("rightKneeAngle"), 0.0)
        assertEquals(80.0, result.getValue("spineAngle"), 0.0)
    }

    @Test
    fun `clamps values just outside the range to the boundary`() {
        // The elbow range is 40 to 180; 35 is 5 outside, within the tolerance.
        val result = PostureMath.clampToPhysiologicalLimits(
            mapOf("rightElbowAngle" to 35.0, "rightKneeAngle" to 185.0),
        )
        assertEquals(40.0, result.getValue("rightElbowAngle"), 0.0)
        assertEquals(180.0, result.getValue("rightKneeAngle"), 0.0)
    }

    @Test
    fun `drops values far outside the range rather than clamping them`() {
        // A 15 degree knee is a bad landmark, not a tight knee. Carrying it
        // forward as a clamped 30 would silently corrupt the score, so the key
        // is omitted and downstream code sees "not measured".
        val result = PostureMath.clampToPhysiologicalLimits(
            mapOf(
                "rightKneeAngle" to 15.0,
                "rightElbowAngle" to 5.0,
                "spineAngle" to 10.0,
            ),
        )
        assertFalse(result.containsKey("rightKneeAngle"))
        assertFalse(result.containsKey("rightElbowAngle"))
        assertFalse(result.containsKey("spineAngle"))
    }

    @Test
    fun `passes through angles with no defined range`() {
        val result = PostureMath.clampToPhysiologicalLimits(mapOf("xFactor" to -35.0))
        assertEquals(-35.0, result.getValue("xFactor"), 0.0)
    }

    @Test
    fun `clamping handles an empty map`() {
        assertTrue(PostureMath.clampToPhysiologicalLimits(emptyMap()).isEmpty())
    }

    // ── mirrorAngles ─────────────────────────────────────────────────────

    @Test
    fun `mirroring swaps left and right for a left-handed thrower`() {
        val mirrored = PostureMath.mirrorAngles(
            mapOf(
                "rightElbowAngle" to 90.0,
                "leftKneeAngle" to 150.0,
                "spineAngle" to 85.0,
            ),
        )
        assertEquals(90.0, mirrored.getValue("leftElbowAngle"), 0.0)
        assertEquals(150.0, mirrored.getValue("rightKneeAngle"), 0.0)
        assertEquals(85.0, mirrored.getValue("spineAngle"), 0.0)
    }

    // ── computeProDeviationScore ─────────────────────────────────────────

    private val proAngles = mapOf(
        "reach_back" to mapOf("rightElbowAngle" to 100.0),
        "power_pocket" to mapOf("rightElbowAngle" to 70.0),
        "release" to mapOf("rightElbowAngle" to 160.0),
        "follow_through" to mapOf("rightElbowAngle" to 120.0),
    )

    @Test
    fun `scoring returns 0 for empty frames`() {
        assertEquals(
            0.0,
            PostureMath.computeProDeviationScore(emptyList(), proAngles, ThrowTypes.BACKHAND),
            0.0,
        )
    }

    @Test
    fun `scoring returns 0 when there is no pro data`() {
        assertEquals(
            0.0,
            PostureMath.computeProDeviationScore(
                listOf(frame(mapOf("rightElbowAngle" to 90.0))),
                emptyMap(),
                ThrowTypes.BACKHAND,
            ),
            0.0,
        )
    }

    @Test
    fun `scores a perfect match at 100`() {
        val score = PostureMath.computeProDeviationScore(
            listOf(
                frame(mapOf("rightElbowAngle" to 100.0)),
                frame(mapOf("rightElbowAngle" to 100.0)),
            ),
            proAngles,
            ThrowTypes.BACKHAND,
            phaseFrameIndices = mapOf("reach_back" to 0),
        )
        assertEquals(100.0, score, 1e-9)
    }

    @Test
    fun `penalises deviation linearly at two points per degree`() {
        val score = PostureMath.computeProDeviationScore(
            listOf(frame(mapOf("rightElbowAngle" to 110.0))),
            proAngles,
            ThrowTypes.BACKHAND,
            phaseFrameIndices = mapOf("reach_back" to 0),
        )
        // 10 degrees off gives 100 - 20 = 80.
        assertEquals(80.0, score, 1e-9)
    }

    @Test
    fun `floors at 0 for extreme deviation rather than going negative`() {
        val score = PostureMath.computeProDeviationScore(
            listOf(frame(mapOf("rightElbowAngle" to 0.0))),
            proAngles,
            ThrowTypes.BACKHAND,
            phaseFrameIndices = mapOf("reach_back" to 0),
        )
        assertEquals(0.0, score, 0.0)
    }

    @Test
    fun `the score is always within 0 to 100`() {
        val score = PostureMath.computeProDeviationScore(
            listOf(
                frame(mapOf("rightElbowAngle" to 20.0)),
                frame(mapOf("rightElbowAngle" to 175.0)),
                frame(mapOf("rightElbowAngle" to 95.0)),
            ),
            proAngles,
            ThrowTypes.BACKHAND,
        )
        assertTrue(score in 0.0..100.0)
    }

    @Test
    fun `ignores angles absent from the pro reference`() {
        val score = PostureMath.computeProDeviationScore(
            listOf(frame(mapOf("rightElbowAngle" to 100.0, "unmatchedAngle" to 999.0))),
            proAngles,
            ThrowTypes.BACKHAND,
            phaseFrameIndices = mapOf("reach_back" to 0),
        )
        // Only the matched angle contributes, so the outlier cannot drag it down.
        assertEquals(100.0, score, 1e-9)
    }

    @Test
    fun `uses forehand phase names for FH`() {
        val fhAngles = mapOf(
            "wind_up" to mapOf("rightElbowAngle" to 90.0),
            "power_pocket" to mapOf("rightElbowAngle" to 70.0),
            "release" to mapOf("rightElbowAngle" to 160.0),
            "follow_through" to mapOf("rightElbowAngle" to 120.0),
        )
        val score = PostureMath.computeProDeviationScore(
            listOf(frame(mapOf("rightElbowAngle" to 90.0))),
            fhAngles,
            ThrowTypes.FOREHAND,
            phaseFrameIndices = mapOf("wind_up" to 0),
        )
        assertEquals(100.0, score, 1e-9)
    }

    @Test
    fun `snaps each frame to its nearest measured phase anchor`() {
        // Frame 0 is at reach_back (pro 100), frame 10 at release (pro 160).
        // A perfect throw matching both should still score 100.
        val frames = (0..10).map { frame(mapOf("rightElbowAngle" to if (it <= 5) 100.0 else 160.0)) }
        val score = PostureMath.computeProDeviationScore(
            frames,
            proAngles,
            ThrowTypes.BACKHAND,
            phaseFrameIndices = mapOf("reach_back" to 0, "release" to 10),
        )
        assertEquals(100.0, score, 1e-9)
    }

    @Test
    fun `falls back to evenly spaced phases without measured indices`() {
        val frames = (0 until 12).map { frame(mapOf("rightElbowAngle" to 100.0)) }
        val score = PostureMath.computeProDeviationScore(frames, proAngles, ThrowTypes.BACKHAND)
        // Not an exact value — only that the fallback path produces a usable
        // score rather than throwing or returning 0.
        assertTrue(score > 0.0)
        assertTrue(score <= 100.0)
    }

    @Test
    fun `frames with no angles contribute nothing but do not crash`() {
        val score = PostureMath.computeProDeviationScore(
            listOf(frame(emptyMap()), frame(mapOf("rightElbowAngle" to 100.0))),
            proAngles,
            ThrowTypes.BACKHAND,
            phaseFrameIndices = mapOf("reach_back" to 0, "release" to 1),
        )
        assertFalse(score.isNaN())
    }

    // ── smoothing ────────────────────────────────────────────────────────

    @Test
    fun `sparse filters skip unmeasured frames instead of propagating them`() {
        val data = listOf(10.0, Double.NaN, 12.0, 100.0, 11.0)

        val median = PostureMath.sparseMedianFilter(data, 3)
        assertFalse(median[3].isNaN())
        // The single spike is replaced by its neighbours' median.
        assertTrue(median[3] < 100.0)

        val averaged = PostureMath.sparseMovingAverage(data, 3)
        assertFalse(averaged[1].isNaN())
    }

    @Test
    fun `a frame with no measurement at all stays unmeasured`() {
        val averaged = PostureMath.sparseMovingAverage(
            listOf(Double.NaN, Double.NaN, Double.NaN),
            3,
        )
        assertTrue(averaged.all { it.isNaN() })
    }

    @Test
    fun `smoothing bridges a one-frame hole in an angle track`() {
        // A frame the detector had nothing to say about takes the value its
        // neighbours imply, rather than leaving a gap in the waveform. Frames
        // where no neighbour was measured either stay absent.
        val frames = listOf(
            frame(mapOf("rightElbowAngle" to 100.0)),
            frame(emptyMap()),
            frame(mapOf("rightElbowAngle" to 104.0)),
            frame(mapOf("rightElbowAngle" to 108.0)),
        )
        PostureMath.smoothFrameAngles(frames)

        assertTrue(frames[1].angles.containsKey("rightElbowAngle"))
        assertTrue(frames[1].angles.getValue("rightElbowAngle") in 100.0..108.0)
    }

    @Test
    fun `smoothing leaves a never-measured angle absent everywhere`() {
        val frames = listOf(frame(emptyMap()), frame(emptyMap()), frame(emptyMap()))
        PostureMath.smoothFrameAngles(frames)

        assertTrue(frames.all { it.angles.isEmpty() })
    }

    // ── phase averaging ──────────────────────────────────────────────────

    @Test
    fun `phase angles average a window around the measured frame`() {
        val frames = (0 until 20).map { frame(mapOf("rightElbowAngle" to it.toDouble())) }
        val phases = PostureMath.extractUserPhaseAngles(
            frames,
            ThrowTypes.BACKHAND,
            mapOf("release" to 10),
        )
        // Frames 8 through 12 average to 10.
        assertEquals(10.0, phases.getValue("release").getValue("rightElbowAngle"), 1e-9)
    }

    // ── FormAnalysis failure reporting ───────────────────────────────────

    @Test
    fun `failureReason round-trips through JSON`() {
        val analysis = FormAnalysis(
            id = "a1",
            date = Instant.parse("2026-01-01T00:00:00Z"),
            videoPath = "/tmp/x.mp4",
            frames = emptyList(),
            score = 0.0,
            isMock = true,
            failureReason = "Analysis failed: boom",
        )

        val restored = FormAnalysis.fromJson(analysis.toJson())
        assertTrue(restored.isMock)
        assertEquals("Analysis failed: boom", restored.failureReason)
    }

    @Test
    fun `legacy records without failureReason still decode`() {
        val restored = FormAnalysis.fromJson(
            Json.parseToJsonElement(
                """
                {
                  "id": "legacy",
                  "date": "2026-01-01T00:00:00.000Z",
                  "videoPath": "/tmp/x.mp4",
                  "frames": [],
                  "score": 0.0,
                  "isMock": true
                }
                """.trimIndent(),
            ).jsonObject,
        )
        assertNull(restored.failureReason)
        assertTrue(restored.isMock)
    }

    @Test
    fun `a form frame round-trips its landmarks and depth`() {
        val original = FormFrame(
            timestampMs = 250,
            angles = mutableMapOf("rightElbowAngle" to 92.5),
            keyPoints = mutableMapOf(
                "PoseLandmarkType.rightElbow" to com.discflightschool.core.geometry.Vec2(0.4, 0.6),
            ),
            landmarkZ = mapOf("PoseLandmarkType.rightElbow" to -0.2),
            landmarkConf = mapOf("PoseLandmarkType.rightElbow" to 0.95),
            imageWidth = 640.0,
            imageHeight = 480.0,
        )

        val restored = FormFrame.fromJson(original.toJson())

        assertEquals(original.timestampMs, restored.timestampMs)
        assertEquals(original.angles, restored.angles)
        assertEquals(original.keyPoints, restored.keyPoints)
        assertEquals(original.landmarkZ, restored.landmarkZ)
        assertEquals(original.landmarkConf, restored.landmarkConf)
        assertEquals(original.imageWidth, restored.imageWidth)
    }
}
