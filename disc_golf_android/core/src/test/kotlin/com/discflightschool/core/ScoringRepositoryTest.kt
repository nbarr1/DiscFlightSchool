package com.discflightschool.core

import com.discflightschool.core.data.InMemoryKeyValueStore
import com.discflightschool.core.data.ScoringRepository
import com.discflightschool.core.model.Hindrance
import com.discflightschool.core.model.HoleScore
import com.discflightschool.core.model.PowerModifier
import com.discflightschool.core.model.RouletteResult
import com.discflightschool.core.model.ScoredRound
import com.discflightschool.core.model.ShotType
import com.discflightschool.core.model.ThrowRecord
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ScoringRepositoryTest {

    private fun challenge() = RouletteResult(
        shotType = ShotType.HYZER,
        powerModifier = PowerModifier.STANDSTILL,
        hindrance = Hindrance.NONE,
        timestamp = Instant.parse("2026-01-01T00:00:00Z"),
    )

    private fun holeScore(player: String, hole: Int, strokes: Int = 3, par: Int = 3) = HoleScore(
        holeNumber = hole,
        par = par,
        strokes = strokes,
        playerName = player,
        throws = listOf(ThrowRecord(throwNumber = 1, challenge = challenge())),
    )

    private fun playRound(repository: ScoringRepository, players: List<String>, holes: Int) {
        for (hole in 1..holes) {
            for (player in players) {
                repository.setCurrentPlayer(player)
                repository.addHoleScore(holeScore(player, hole))
            }
        }
    }

    private val holes = ScoredRound.defaultCourse().size

    @Test
    fun `a completed round is saved exactly once`() {
        val repository = ScoringRepository(InMemoryKeyValueStore())
        repository.startNewRound(listOf("Alice"))

        playRound(repository, listOf("Alice"), holes)

        assertEquals(1, repository.savedRounds.value.size)
    }

    @Test
    fun `undoing and re-entering the final hole does not save the round twice`() {
        // Saving on completion plus an unconditional append would persist the
        // same round a second time and double-count it in the statistics.
        val repository = ScoringRepository(InMemoryKeyValueStore())
        repository.startNewRound(listOf("Alice"))

        playRound(repository, listOf("Alice"), holes)
        assertEquals(1, repository.savedRounds.value.size)

        repository.undoLastScore()
        assertFalse(repository.currentRound.value!!.isComplete)

        repository.setCurrentPlayer("Alice")
        repository.addHoleScore(holeScore("Alice", holes, strokes = 4))

        assertEquals(
            "the round should be updated in place, not appended again",
            1,
            repository.savedRounds.value.size,
        )
        // And the correction should be the version that survives.
        assertEquals(4, repository.savedRounds.value.single().scores.last().strokes)
    }

    @Test
    fun `repeated undo and redo cycles never accumulate duplicates`() {
        val repository = ScoringRepository(InMemoryKeyValueStore())
        repository.startNewRound(listOf("Alice"))
        playRound(repository, listOf("Alice"), holes)

        for (i in 0 until 5) {
            repository.undoLastScore()
            repository.setCurrentPlayer("Alice")
            repository.addHoleScore(holeScore("Alice", holes, strokes = 3 + i))
        }

        assertEquals(1, repository.savedRounds.value.size)
    }

    @Test
    fun `statistics count a round once per player`() {
        val repository = ScoringRepository(InMemoryKeyValueStore())
        repository.startNewRound(listOf("Alice", "Bob"))

        playRound(repository, listOf("Alice", "Bob"), holes)

        repository.undoLastScore()
        repository.setCurrentPlayer("Bob")
        repository.addHoleScore(holeScore("Bob", holes))

        val stats = repository.statistics()
        assertEquals(1, stats.totalRounds)
        assertEquals(1, stats.playerRoundsPlayed["Alice"])
        assertEquals(1, stats.playerRoundsPlayed["Bob"])
    }

    @Test
    fun `one corrupt stored round does not discard the others`() {
        val good = ScoredRound(
            id = "good-1",
            playerNames = listOf("Alice"),
            startedAt = Instant.parse("2026-01-01T00:00:00Z"),
            completedAt = Instant.parse("2026-01-01T01:00:00Z"),
            coursePars = ScoredRound.defaultCourse(),
            scores = emptyList(),
        )

        val store = InMemoryKeyValueStore(
            mapOf(
                ScoringRepository.KEY to listOf(
                    good.toJson().toString(),
                    "{ this is not valid json",
                    """{"id": "missing-required-fields"}""",
                ),
            ),
        )

        val repository = ScoringRepository(store)

        assertEquals(1, repository.savedRounds.value.size)
        assertEquals("good-1", repository.savedRounds.value.single().id)
    }

    @Test
    fun `a fully corrupt store still leaves the repository usable`() {
        val store = InMemoryKeyValueStore(
            mapOf(ScoringRepository.KEY to listOf("nonsense", "also nonsense")),
        )
        val repository = ScoringRepository(store)

        assertTrue(repository.savedRounds.value.isEmpty())

        // Saving must still work after a bad load.
        repository.startNewRound(listOf("Alice"))
        playRound(repository, listOf("Alice"), holes)

        assertEquals(1, repository.savedRounds.value.size)
    }

    @Test
    fun `saved rounds survive a reload from the same store`() {
        val store = InMemoryKeyValueStore()
        val repository = ScoringRepository(store)
        repository.startNewRound(listOf("Alice"))
        playRound(repository, listOf("Alice"), holes)

        val reloaded = ScoringRepository(store)
        assertEquals(1, reloaded.savedRounds.value.size)
        assertEquals(holes, reloaded.savedRounds.value.single().scores.size)
    }

    @Test
    fun `undo clears the completed timestamp`() {
        val repository = ScoringRepository(InMemoryKeyValueStore())
        repository.startNewRound(listOf("Alice"))
        playRound(repository, listOf("Alice"), holes)

        assertTrue(repository.currentRound.value!!.completedAt != null)
        repository.undoLastScore()
        assertNull(repository.currentRound.value!!.completedAt)
    }

    @Test
    fun `undo on an empty round is a no-op`() {
        val repository = ScoringRepository(InMemoryKeyValueStore())
        repository.startNewRound(listOf("Alice"))
        repository.undoLastScore()
        assertTrue(repository.currentRound.value!!.scores.isEmpty())
    }

    @Test
    fun `addHoleScore without an active round is ignored`() {
        val repository = ScoringRepository(InMemoryKeyValueStore())
        repository.addHoleScore(holeScore("Alice", 1))
        assertNull(repository.currentRound.value)
    }

    @Test
    fun `statistics are empty when nothing is saved`() {
        assertTrue(ScoringRepository(InMemoryKeyValueStore()).statistics().isEmpty)
    }

    @Test
    fun `roundById returns null for an unknown id`() {
        assertNull(ScoringRepository(InMemoryKeyValueStore()).roundById("nope"))
    }

    @Test
    fun `weighted scoring reflects the difficulty of the throws taken`() {
        val hardChallenge = RouletteResult(
            shotType = ShotType.GRENADE,
            powerModifier = PowerModifier.OVERHAND,
            hindrance = Hindrance.EYES_CLOSED,
            timestamp = Instant.parse("2026-01-01T00:00:00Z"),
        )
        val hole = HoleScore(
            holeNumber = 1,
            par = 3,
            strokes = 5,
            playerName = "Alice",
            throws = listOf(ThrowRecord(1, hardChallenge)),
        )

        assertEquals(2, hole.rawScore)
        assertEquals(3.6, hole.averageMultiplier, 1e-12)
        assertEquals(7.2, hole.weightedScore, 1e-12)
    }

    @Test
    fun `a deleted round is gone from the store as well`() {
        val store = InMemoryKeyValueStore()
        val repository = ScoringRepository(store)
        repository.startNewRound(listOf("Alice"))
        playRound(repository, listOf("Alice"), holes)
        val id = repository.savedRounds.value.single().id

        repository.deleteRound(id)

        assertTrue(repository.savedRounds.value.isEmpty())
        assertTrue(ScoringRepository(store).savedRounds.value.isEmpty())
    }
}
