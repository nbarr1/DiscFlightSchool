package com.discflightschool.core

import com.discflightschool.core.tracking.LinearAssignment
import com.discflightschool.core.tracking.OcSortSettings
import com.discflightschool.core.tracking.OcSortTracker
import com.discflightschool.core.tracking.PixelBox
import com.discflightschool.core.tracking.TrackerDetection
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OcSortTrackerTest {

    /**
     * The fixture is Roboflow's own tracker (`trackers` 2.4.0) run over
     * synthetic flights by scripts/generate_ocsort_fixture.py. The port must
     * keep the same detections, with the same ids, on every frame.
     */
    @Test
    fun `matches Roboflow's tracker frame for frame`() {
        val text = javaClass.getResource("/ocsort_fixture.json")!!.readText()
        val root = Json.parseToJsonElement(text).jsonObject
        val scenarios = root["scenarios"]!!.jsonArray
        assertTrue(scenarios.size >= 4)
        for (scenario in scenarios.map { it.jsonObject }) {
            val seed = scenario.int("seed")
            val tracker = OcSortTracker(fps = scenario.double("fps"))
            scenario["frames"]!!.jsonArray.forEachIndexed { frame, element ->
                val data = element.jsonObject
                val detections = data["detections"]!!.jsonArray.map { item ->
                    val box = item.jsonObject["box"]!!.jsonArray.map { it.jsonPrimitive.double }
                    TrackerDetection(PixelBox(box[0], box[1], box[2], box[3]), item.jsonObject.double("confidence"))
                }
                val expected = data["tracked"]!!.jsonArray.map {
                    OcSortTracker.Tracked(it.jsonObject.int("index"), it.jsonObject.int("trackerId"))
                }
                assertEquals("seed $seed, frame $frame", expected, tracker.update(detections))
            }
        }
    }

    @Test
    fun `a new detection gets an id from its second frame`() {
        val tracker = OcSortTracker(fps = 30.0)
        val first = TrackerDetection(PixelBox(100.0, 100.0, 120.0, 112.0), 0.8)
        val second = TrackerDetection(PixelBox(108.0, 98.0, 128.0, 110.0), 0.8)
        assertEquals(emptyList<OcSortTracker.Tracked>(), tracker.update(listOf(first)))
        assertEquals(listOf(OcSortTracker.Tracked(0, 0)), tracker.update(listOf(second)))
    }

    @Test
    fun `detections under the confidence threshold are never tracked`() {
        val tracker = OcSortTracker(fps = 30.0, settings = OcSortSettings(highConfidenceThreshold = 0.5))
        val box = PixelBox(100.0, 100.0, 120.0, 112.0)
        repeat(3) { assertEquals(emptyList<OcSortTracker.Tracked>(), tracker.update(listOf(TrackerDetection(box, 0.4)))) }
    }

    @Test
    fun `assignment maximizes the total and handles wide and tall matrices`() {
        val square = arrayOf(
            doubleArrayOf(0.1, 0.9, 0.0),
            doubleArrayOf(0.8, 0.7, 0.0),
            doubleArrayOf(0.0, 0.2, 0.3),
        )
        assertEquals(listOf(0 to 1, 1 to 0, 2 to 2), LinearAssignment.maximize(square))
        val tall = arrayOf(doubleArrayOf(0.2), doubleArrayOf(0.9), doubleArrayOf(0.5))
        assertEquals(listOf(1 to 0), LinearAssignment.maximize(tall))
        val wide = arrayOf(doubleArrayOf(0.2, 0.9, 0.5))
        assertEquals(listOf(0 to 1), LinearAssignment.maximize(wide))
    }

    private fun JsonObject.int(key: String) = this[key]!!.jsonPrimitive.int
    private fun JsonObject.double(key: String) = this[key]!!.jsonPrimitive.double
}
