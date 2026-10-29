package com.discflightschool.core

import com.discflightschool.core.detection.PilBilinear
import com.discflightschool.core.detection.RfDetrConfig
import com.discflightschool.core.detection.RfDetrInput
import com.discflightschool.core.detection.RfDetrOutput
import com.discflightschool.core.tracking.PixelBox
import kotlin.math.ln
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class RfDetrTest {

    /** The bundled package's files, as Roboflow exports them. */
    private val inferenceConfig = """
        {"image_pre_processing": {"auto-orient": {"enabled": true}}, "network_input": {"training_input_size":
        {"height": 512, "width": 512}, "dynamic_spatial_size_supported": false, "color_mode": "rgb",
        "resize_mode": "stretch", "padding_value": null, "input_channels": 3, "scaling_factor": 255,
        "normalization": [[0.485, 0.456, 0.406], [0.229, 0.224, 0.225]], "dataset_version_resize_dimensions":
        {"height": 512, "width": 512}}, "class_names_operations": [{"type": "class_name_removal",
        "class_name": "background_class83422"}]}
    """
    private val config = RfDetrConfig.parse(inferenceConfig, "background_class83422\ndisc\n")

    @Test
    fun `reads the package's preprocessing and classes`() {
        assertEquals(512, config.inputWidth)
        assertEquals(512, config.inputHeight)
        assertArrayEquals(floatArrayOf(0.485f, 0.456f, 0.406f), config.mean, 0f)
        assertArrayEquals(floatArrayOf(0.229f, 0.224f, 0.225f), config.std, 0f)
        assertEquals(1, config.classIndex("disc"))
        assertEquals(-1, config.classIndex("background_class83422"))
    }

    @Test
    fun `refuses preprocessing it does not implement`() {
        for (change in listOf("\"stretch\"" to "\"letterbox\"", "\"auto-orient\"" to "\"contrast\"")) {
            assertThrows(IllegalArgumentException::class.java) {
                RfDetrConfig.parse(inferenceConfig.replace(change.first, change.second), "disc")
            }
        }
    }

    /** scripts/generate_pil_resize_fixture.py: Pillow's own output for random images. */
    @Test
    fun `resizes exactly as Pillow does`() {
        val text = javaClass.getResource("/pil_resize_fixture.json")!!.readText()
        for (case in Json.parseToJsonElement(text).jsonObject["cases"]!!.jsonArray.map { it.jsonObject }) {
            val width = case["width"]!!.jsonPrimitive.int
            val height = case["height"]!!.jsonPrimitive.int
            val outWidth = case["outWidth"]!!.jsonPrimitive.int
            val outHeight = case["outHeight"]!!.jsonPrimitive.int
            val rgb = case["pixels"]!!.jsonArray.map { it.jsonPrimitive.int }
            val pixels = IntArray(width * height) { i ->
                (0xFF shl 24) or (rgb[i * 3] shl 16) or (rgb[i * 3 + 1] shl 8) or rgb[i * 3 + 2]
            }
            val expected = case["resized"]!!.jsonArray.map { it.jsonPrimitive.int }

            val resized = PilBilinear.resize(pixels, width, height, outWidth, outHeight)

            val actual = resized.flatMap { listOf((it shr 16) and 0xFF, (it shr 8) and 0xFF, it and 0xFF) }
            assertEquals("${width}x$height to ${outWidth}x$outHeight", expected, actual)
        }
    }

    @Test
    fun `normalizes each channel into planes`() {
        val small = config.copy(inputWidth = 2, inputHeight = 1)
        val out = FloatArray(6)
        // Already the input size, so the resize leaves the pixels alone.
        RfDetrInput.write(intArrayOf(0xFFFF0000.toInt(), 0xFF00FF80.toInt()), 2, 1, small, out)

        val expected = floatArrayOf(
            (1f - 0.485f) / 0.229f, (0f - 0.485f) / 0.229f,
            (0f - 0.456f) / 0.224f, (1f - 0.456f) / 0.224f,
            (0f - 0.406f) / 0.225f, (128 / 255f - 0.406f) / 0.225f,
        )
        assertArrayEquals(expected, out, 1e-6f)
    }

    private fun logit(p: Double) = ln(p / (1 - p)).toFloat()

    @Test
    fun `decodes disc boxes into frame pixels, most confident first`() {
        // Three queries: a weak disc, a confident disc, and one that is background.
        val boxes = floatArrayOf(
            0.25f, 0.5f, 0.1f, 0.2f,
            0.5f, 0.5f, 0.2f, 0.1f,
            0.9f, 0.9f, 0.1f, 0.1f,
        )
        val logits = floatArrayOf(
            logit(0.01), logit(0.3),
            logit(0.02), logit(0.9),
            logit(0.95), logit(0.1),
        )

        val detections = RfDetrOutput.decode(boxes, logits, 2, config.classIndex("disc"), 0.15, config, 1920, 1080)

        assertEquals(listOf(0.9, 0.3), detections.map { Math.round(it.confidence * 100) / 100.0 })
        assertEquals(PixelBox(768.0, 486.0, 1152.0, 594.0), detections[0].box)
        // 0.2 x 1920 = 384 and 0.4 x 1080 = 432, with corners rounded to whole pixels.
        assertEquals(PixelBox(384.0, 432.0, 576.0, 648.0), detections[1].box)
    }

    @Test
    fun `a score at the threshold is not a detection`() {
        val detections = RfDetrOutput.decode(
            floatArrayOf(0.5f, 0.5f, 0.1f, 0.1f),
            floatArrayOf(logit(0.01), 0f),
            2, 1, 0.5, config, 100, 100,
        )
        assertEquals(0, detections.size)
    }

    @Test
    fun `only the top scores across all classes count, as torch topk takes them`() {
        // Two queries, so only two of the four scores are considered: both
        // background scores beat the disc score.
        val detections = RfDetrOutput.decode(
            floatArrayOf(0.5f, 0.5f, 0.1f, 0.1f, 0.2f, 0.2f, 0.1f, 0.1f),
            floatArrayOf(logit(0.9), logit(0.4), logit(0.8), logit(0.2)),
            2, 1, 0.15, config, 100, 100,
        )
        assertEquals(0, detections.size)
    }
}
