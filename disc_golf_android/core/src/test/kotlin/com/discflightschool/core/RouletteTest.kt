package com.discflightschool.core

import com.discflightschool.core.data.InMemoryKeyValueStore
import com.discflightschool.core.data.RouletteHistoryRepository
import com.discflightschool.core.model.DiscLists
import com.discflightschool.core.model.Hindrance
import com.discflightschool.core.model.PowerModifier
import com.discflightschool.core.model.PuttStyle
import com.discflightschool.core.model.RouletteResult
import com.discflightschool.core.model.ShotType
import java.time.Instant
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RouletteTest {

    @Test
    fun `difficulty stacks shot type, power, and hindrance`() {
        val easy = RouletteResult(
            shotType = ShotType.FLAT,
            powerModifier = PowerModifier.FULL_POWER,
            hindrance = Hindrance.NONE,
            timestamp = Instant.EPOCH,
        )
        assertEquals(1.0, easy.difficultyMultiplier, 1e-12)

        val hard = RouletteResult(
            shotType = ShotType.GRENADE, // +0.7
            powerModifier = PowerModifier.OVERHAND, // +0.4
            hindrance = Hindrance.EYES_CLOSED, // +1.5
            timestamp = Instant.EPOCH,
        )
        assertEquals(3.6, hard.difficultyMultiplier, 1e-12)
    }

    @Test
    fun `putt style contributes to difficulty`() {
        val putt = RouletteResult(
            shotType = ShotType.FLAT,
            powerModifier = PowerModifier.STANDSTILL, // +0.2
            hindrance = Hindrance.NONE,
            puttStyle = PuttStyle.TURBO, // +0.7
            timestamp = Instant.EPOCH,
        )
        assertEquals(1.9, putt.difficultyMultiplier, 1e-12)
        assertTrue(putt.isPutt)
    }

    @Test
    fun `generate never pairs a ground hindrance with a run-up`() {
        // You cannot run or x-step from the ground, or run on one leg.
        val grounded = setOf(Hindrance.KNEELING, Hindrance.SITTING, Hindrance.ONE_LEG)
        val random = Random(20260916)

        repeat(2000) {
            val result = RouletteResult.generate(DiscLists.all, random, Instant.EPOCH)
            if (result.hindrance in grounded) {
                assertFalse(
                    "${result.hindrance} paired with ${result.powerModifier}",
                    result.powerModifier == PowerModifier.RUN_UP ||
                        result.powerModifier == PowerModifier.X_STEP,
                )
            }
        }
    }

    @Test
    fun `generatePutt always spins a flat standstill putt with a style`() {
        val random = Random(7)
        repeat(50) {
            val putt = RouletteResult.generatePutt(DiscLists.putting, random, Instant.EPOCH)
            assertEquals(ShotType.FLAT, putt.shotType)
            assertEquals(PowerModifier.STANDSTILL, putt.powerModifier)
            assertEquals(Hindrance.NONE, putt.hindrance)
            assertNotNull(putt.puttStyle)
            assertEquals("Putter", putt.discName)
        }
    }

    @Test
    fun `generate tolerates an empty disc list`() {
        val result = RouletteResult.generate(emptyList(), Random(1), Instant.EPOCH)
        assertEquals(null, result.discName)
    }

    @Test
    fun `history keeps the newest spin first and survives a reload`() {
        val store = InMemoryKeyValueStore()
        val repository = RouletteHistoryRepository(store)

        val first = RouletteResult.generate(DiscLists.all, Random(1), Instant.EPOCH)
        val second = RouletteResult.generate(DiscLists.all, Random(2), Instant.EPOCH.plusSeconds(1))
        repository.addResult(first)
        repository.addResult(second)

        assertEquals(listOf(second, first), repository.history.value)
        // A fresh repository over the same store sees the same order.
        assertEquals(listOf(second, first), RouletteHistoryRepository(store).history.value)
    }

    @Test
    fun `history is capped and drops the oldest spins`() {
        val repository = RouletteHistoryRepository(InMemoryKeyValueStore())
        repeat(RouletteHistoryRepository.MAX_ENTRIES + 25) { i ->
            repository.addResult(
                RouletteResult.generate(DiscLists.all, Random(i), Instant.EPOCH.plusSeconds(i.toLong())),
            )
        }
        assertEquals(RouletteHistoryRepository.MAX_ENTRIES, repository.history.value.size)
    }

    @Test
    fun `a corrupt history entry does not discard the rest`() {
        val good = RouletteResult.generate(DiscLists.all, Random(3), Instant.EPOCH)
        val store = InMemoryKeyValueStore(
            mapOf(
                RouletteHistoryRepository.KEY to
                    """[${good.toJson()}, {"shotType": "not-a-shot"}]""",
            ),
        )

        assertEquals(listOf(good), RouletteHistoryRepository(store).history.value)
    }

    @Test
    fun `an unreadable history string leaves the repository usable`() {
        val store = InMemoryKeyValueStore(
            mapOf(RouletteHistoryRepository.KEY to "{ this is not json"),
        )
        val repository = RouletteHistoryRepository(store)

        assertTrue(repository.history.value.isEmpty())

        val spin = RouletteResult.generate(DiscLists.all, Random(4), Instant.EPOCH)
        repository.addResult(spin)
        assertEquals(listOf(spin), repository.history.value)
    }
}
