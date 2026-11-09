package com.discflightschool.core

import com.discflightschool.core.baseline.ProBaselineDatabase
import com.discflightschool.core.data.FormHistoryRepository
import com.discflightschool.core.data.InMemoryKeyValueStore
import com.discflightschool.core.model.FormSessionRecord
import com.discflightschool.core.model.ThrowTypes
import java.time.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The plant phase mark and the optional self-reported throw distance. */
class FormSessionDistanceTest {

    private fun record(id: String = "s1", distanceFeet: Double? = null) = FormSessionRecord(
        id = id,
        date = Instant.parse("2026-11-09T12:00:00Z"),
        score = 0.0,
        throwType = ThrowTypes.BACKHAND,
        frameCount = 40,
        distanceFeet = distanceFeet,
    )

    @Test
    fun plantIsMarkedAfterTheReachBackOrWindUp() {
        assertEquals(
            listOf("reach_back", "plant", "power_pocket", "release", "follow_through"),
            ProBaselineDatabase.markedPhaseNames(ThrowTypes.BACKHAND),
        )
        assertEquals(
            listOf("wind_up", "plant", "power_pocket", "release", "follow_through"),
            ProBaselineDatabase.markedPhaseNames(ThrowTypes.FOREHAND),
        )
    }

    @Test
    fun baselinePhasesDoNotIncludePlant() {
        // The pro baseline has no plant data: pro comparison must not expect it.
        assertFalse(ProBaselineDatabase.PLANT in ProBaselineDatabase.phaseNames(ThrowTypes.BACKHAND))
        assertFalse(ProBaselineDatabase.PLANT in ProBaselineDatabase.phaseNames(ThrowTypes.FOREHAND))
    }

    @Test
    fun distanceRoundTripsThroughJson() {
        val restored = FormSessionRecord.fromJson(record(distanceFeet = 285.0).toJson())
        assertEquals(285.0, restored.distanceFeet!!, 0.0)
    }

    @Test
    fun missingOrNullDistanceLoadsAsNull() {
        assertNull(FormSessionRecord.fromJson(record().toJson()).distanceFeet)

        // A record saved before the field existed has no distanceFeet key.
        val old = Json.parseToJsonElement(
            """{"id":"old","date":"2026-01-01T00:00:00.000Z","score":72.5,""" +
                """"throwType":"BH","proPlayer":null,"frameCount":30,"avgAngles":{}}""",
        ).jsonObject
        assertNull(FormSessionRecord.fromJson(old).distanceFeet)
    }

    @Test
    fun setDistanceUpdatesPersistsAndClears() {
        val store = InMemoryKeyValueStore()
        val repository = FormHistoryRepository(store)
        repository.saveSession(record("a"))
        repository.saveSession(record("b"))

        assertTrue(repository.setDistance("a", 310.0))
        assertEquals(310.0, repository.sessions.value.first { it.id == "a" }.distanceFeet!!, 0.0)
        assertNull(repository.sessions.value.first { it.id == "b" }.distanceFeet)

        // Survives a reload from the store.
        val reloaded = FormHistoryRepository(store)
        assertEquals(310.0, reloaded.sessions.value.first { it.id == "a" }.distanceFeet!!, 0.0)

        assertTrue(repository.setDistance("a", null))
        assertNull(repository.sessions.value.first { it.id == "a" }.distanceFeet)
    }

    @Test
    fun setDistanceRejectsUnknownSessionsAndBadValues() {
        val repository = FormHistoryRepository(InMemoryKeyValueStore())
        repository.saveSession(record("a"))

        assertFalse(repository.setDistance("missing", 200.0))

        repository.setDistance("a", -5.0)
        assertNull(repository.sessions.value.first().distanceFeet)
        repository.setDistance("a", Double.NaN)
        assertNull(repository.sessions.value.first().distanceFeet)
    }
}
