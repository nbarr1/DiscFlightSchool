package com.discflightschool.core

import com.discflightschool.core.model.DetectorModelVersion
import com.discflightschool.core.model.FormSessionRecord
import com.discflightschool.core.model.Hindrance
import com.discflightschool.core.model.HoleScore
import com.discflightschool.core.model.PowerModifier
import com.discflightschool.core.model.RouletteResult
import com.discflightschool.core.model.ShotType
import com.discflightschool.core.model.ThrowTypes
import com.discflightschool.core.model.TrainingSample
import java.time.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The shapes persisted by earlier versions of the app must keep loading.
 *
 * A user's saved rounds, form history, and pending training samples live on the
 * device across upgrades, so these are the records the rewrite has to keep
 * reading, not just the ones it now writes.
 */
class DataContractsTest {

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    private fun parse(raw: String) = json.parseToJsonElement(raw).jsonObject

    @Test
    fun `TrainingSample preserves legacy uploaded default and YOLO formatting`() {
        val sample = TrainingSample.fromJson(
            parse(
                """
                {
                  "id": "sample-1",
                  "imagePath": "/tmp/full.jpg",
                  "cropPath": "/tmp/crop.jpg",
                  "centerX": 0.5,
                  "centerY": 0.25,
                  "boxWidth": 0.125,
                  "boxHeight": 0.0625,
                  "frameIndex": 3,
                  "imageWidth": 640,
                  "imageHeight": 360,
                  "createdAt": "2026-05-07T00:00:00.000Z"
                }
                """.trimIndent(),
            ),
        )

        assertFalse(sample.uploaded)
        assertEquals("0 0.500000 0.250000 0.125000 0.062500", sample.toYoloLabel())
    }

    @Test
    fun `TrainingSample clamps YOLO labels to normalized bounds`() {
        val sample = TrainingSample(
            id = "sample-2",
            imagePath = "/tmp/full.jpg",
            cropPath = "/tmp/crop.jpg",
            centerX = 1.5,
            centerY = -0.2,
            boxWidth = 2.0,
            boxHeight = 0.0,
            frameIndex = 1,
            imageWidth = 640,
            imageHeight = 360,
            createdAt = Instant.parse("2026-05-31T00:00:00Z"),
        )

        assertEquals("0 1.000000 0.000000 1.000000 0.000001", sample.toYoloLabel())
    }

    @Test
    fun `YOLO labels satisfy the server validator`() {
        // Mirrors server/training_server/validation.py's YOLO_LABEL regex.
        val serverPattern = Regex(
            """^0\s+(?:0(?:\.\d+)?|1(?:\.0+)?)\s+(?:0(?:\.\d+)?|1(?:\.0+)?)""" +
                """\s+(?:0(?:\.\d+)?|1(?:\.0+)?)\s+(?:0(?:\.\d+)?|1(?:\.0+)?)$""",
        )

        for (value in listOf(0.0, 1.0, 0.999999, 0.5)) {
            val sample = TrainingSample(
                id = "s",
                imagePath = "a",
                cropPath = "b",
                centerX = value,
                centerY = value,
                boxWidth = value,
                boxHeight = value,
                frameIndex = 0,
                imageWidth = 100,
                imageHeight = 100,
                createdAt = Instant.parse("2026-01-01T00:00:00Z"),
            )
            val label = sample.toYoloLabel()
            assertTrue("value $value produced $label", serverPattern.matches(label))
        }
    }

    @Test
    fun `HoleScore still reads legacy single challenge JSON`() {
        val challenge = RouletteResult(
            shotType = ShotType.HYZER,
            powerModifier = PowerModifier.STANDSTILL,
            hindrance = Hindrance.NONE,
            timestamp = Instant.parse("2026-05-07T00:00:00Z"),
        )

        val score = HoleScore.fromJson(
            buildJsonObject {
                put("holeNumber", JsonPrimitive(1))
                put("par", JsonPrimitive(3))
                put("strokes", JsonPrimitive(4))
                put("challenge", challenge.toJson())
                put("playerName", JsonPrimitive("Player 1"))
            },
        )

        assertEquals(1, score.throws.size)
        assertEquals(1, score.throws.single().throwNumber)
        assertEquals("Player 1", score.playerName)
    }

    @Test
    fun `FormSessionRecord preserves the default throw type for legacy JSON`() {
        val record = FormSessionRecord.fromJson(
            parse(
                """
                {
                  "id": "form-1",
                  "date": "2026-05-07T00:00:00.000Z",
                  "score": 87,
                  "frameCount": 4,
                  "avgAngles": {"elbow": 123.4}
                }
                """.trimIndent(),
            ),
        )

        assertEquals(ThrowTypes.BACKHAND, record.throwType)
        assertEquals(123.4, record.avgAngles.getValue("elbow"), 1e-9)
    }

    @Test
    fun `DetectorModelVersion exposes the no-model sentinel`() {
        val version = DetectorModelVersion.fromJson(
            parse("""{"version": "none", "sha256": "", "url": ""}"""),
        )
        assertFalse(version.hasModel)

        val real = DetectorModelVersion.fromJson(
            parse("""{"version": "2026-05-07", "sha256": "abc", "url": "/api/model/download"}"""),
        )
        assertTrue(real.hasModel)
    }

    @Test
    fun `a roulette result round-trips through JSON`() {
        val result = RouletteResult(
            shotType = ShotType.SCOOBER,
            discName = "Midrange",
            powerModifier = PowerModifier.X_STEP,
            hindrance = Hindrance.OFF_HAND,
            timestamp = Instant.parse("2026-05-07T12:34:56Z"),
        )

        val restored = RouletteResult.fromJson(result.toJson())

        assertEquals(result, restored)
        assertEquals(result.difficultyMultiplier, restored.difficultyMultiplier, 1e-12)
    }

    @Test
    fun `a form session record round-trips through JSON`() {
        val record = FormSessionRecord(
            id = "form-2",
            date = Instant.parse("2026-05-07T00:00:00Z"),
            score = 72.5,
            throwType = ThrowTypes.FOREHAND,
            proPlayer = "Wysocki",
            frameCount = 30,
            avgAngles = mapOf("rightElbowAngle" to 94.0),
        )

        assertEquals(record, FormSessionRecord.fromJson(record.toJson()))
    }
}
