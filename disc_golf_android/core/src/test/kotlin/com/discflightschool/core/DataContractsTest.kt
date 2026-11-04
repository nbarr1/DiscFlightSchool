package com.discflightschool.core

import com.discflightschool.core.model.FormSessionRecord
import com.discflightschool.core.model.Hindrance
import com.discflightschool.core.model.HoleScore
import com.discflightschool.core.model.PowerModifier
import com.discflightschool.core.model.RouletteResult
import com.discflightschool.core.model.ShotType
import com.discflightschool.core.model.ThrowTypes
import java.time.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The shapes persisted by earlier versions of the app must keep loading.
 *
 * A user's saved rounds and form history live on the device across upgrades,
 * so these are the records the rewrite has to keep reading, not just the ones
 * it now writes.
 */
class DataContractsTest {

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    private fun parse(raw: String) = json.parseToJsonElement(raw).jsonObject

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
