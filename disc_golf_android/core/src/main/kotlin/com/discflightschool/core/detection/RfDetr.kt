package com.discflightschool.core.detection

import com.discflightschool.core.tracking.PixelBox
import com.discflightschool.core.tracking.TrackerDetection
import kotlin.math.ceil
import kotlin.math.exp
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * What the bundled RF-DETR package says about its input: its
 * `inference_config.json` and `class_names.txt`, as Roboflow exports them.
 */
data class RfDetrConfig(
    val inputWidth: Int,
    val inputHeight: Int,
    val mean: FloatArray,
    val std: FloatArray,
    /** Every class the network scores, in output order, background included. */
    val classNames: List<String>,
    /** Classes the package drops from the output, such as Roboflow's background class. */
    val removedClasses: Set<String>,
) {
    /** The output index of the class named [name], or -1 when the model has none or drops it. */
    fun classIndex(name: String): Int =
        classNames.indexOf(name).takeIf { it >= 0 && name !in removedClasses } ?: -1

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        /**
         * @throws IllegalArgumentException when the package needs preprocessing
         *   this port does not implement, so a retrained model fails loudly
         *   rather than running on the wrong input.
         */
        fun parse(inferenceConfig: String, classNames: String): RfDetrConfig {
            val root = json.parseToJsonElement(inferenceConfig).jsonObject
            val input = root["network_input"]?.jsonObject
                ?: throw IllegalArgumentException("inference_config.json has no network_input.")
            val resize = input.string("resize_mode")
            require(resize == "stretch") { "Unsupported resize mode $resize; only stretch is implemented." }
            require(input.string("color_mode") == "rgb") { "Only RGB models are supported." }
            val size = input["training_input_size"]?.jsonObject
                ?: throw IllegalArgumentException("inference_config.json has no training_input_size.")
            val normalization = input["normalization"] as? JsonArray
            val scaling = (input["scaling_factor"] as? JsonPrimitive)?.doubleOrNull ?: 255.0
            require(normalization != null || scaling == 255.0) { "Only /255 scaling is implemented." }
            val preprocessing = root["image_pre_processing"]?.jsonObject.orEmpty()
            for ((step, settings) in preprocessing) {
                val enabled = (settings as? JsonObject)?.get("enabled")?.jsonPrimitive?.content == "true"
                // Frames come from the decoder upright, so auto-orient has nothing to do.
                require(!enabled || step == "auto-orient") { "Unsupported preprocessing step $step." }
            }
            val removed = (root["class_names_operations"] as? JsonArray).orEmpty()
                .map { it.jsonObject }
                .filter { it.string("type") == "class_name_removal" }
                .mapNotNull { it.string("class_name") }
                .toSet()
            return RfDetrConfig(
                inputWidth = size["width"]!!.jsonPrimitive.intOrNull!!,
                inputHeight = size["height"]!!.jsonPrimitive.intOrNull!!,
                mean = normalization?.get(0)?.floats() ?: floatArrayOf(0f, 0f, 0f),
                std = normalization?.get(1)?.floats() ?: floatArrayOf(1f, 1f, 1f),
                classNames = classNames.lines().map { it.trim() }.filter { it.isNotEmpty() },
                removedClasses = removed,
            )
        }

        private fun JsonObject.string(key: String) = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

        private fun kotlinx.serialization.json.JsonElement.floats() =
            jsonArray.map { it.jsonPrimitive.doubleOrNull!!.toFloat() }.toFloatArray()
    }
}

/**
 * RF-DETR preprocessing as Roboflow's `inference-models` does it for a
 * stretch-resized RGB model: PIL's bilinear resize of the whole frame to the
 * network size, `to_tensor` (/255), then per-channel normalization, NCHW.
 */
object RfDetrInput {
    /**
     * Write [pixels] (`0xAARRGGBB`, [width] x [height], row-major) into [out],
     * which holds `3 * inputWidth * inputHeight` floats.
     */
    fun write(pixels: IntArray, width: Int, height: Int, config: RfDetrConfig, out: FloatArray) {
        val w = config.inputWidth
        val h = config.inputHeight
        require(out.size == 3 * w * h) { "Input buffer holds ${out.size} floats, expected ${3 * w * h}." }
        val resized = PilBilinear.resize(pixels, width, height, w, h)
        val plane = w * h
        for (i in 0 until plane) {
            val p = resized[i]
            for (c in 0 until 3) {
                val value = (p shr (16 - 8 * c)) and 0xFF
                out[c * plane + i] = (value / 255f - config.mean[c]) / config.std[c]
            }
        }
    }
}

/**
 * Pillow's `Image.resize(size, Image.BILINEAR)` on an 8-bit RGB image
 * (`libImaging/Resample.c`): a triangle filter widened by the scale factor
 * when shrinking, applied horizontally then vertically, with Pillow's 22-bit
 * fixed-point coefficients and rounding.
 */
object PilBilinear {
    private const val PRECISION_BITS = 32 - 8 - 2

    private class Coefficients(val bounds: IntArray, val kernel: IntArray, val size: Int)

    fun resize(pixels: IntArray, width: Int, height: Int, outWidth: Int, outHeight: Int): IntArray {
        var current = pixels
        var currentWidth = width
        if (outWidth != width) {
            val coefficients = coefficients(width, outWidth)
            current = IntArray(outWidth * height) { index ->
                val y = index / outWidth
                convolve(coefficients, index % outWidth) { x -> pixels[y * width + x] }
            }
            currentWidth = outWidth
        }
        if (outHeight != height) {
            val source = current
            val coefficients = coefficients(height, outHeight)
            current = IntArray(outWidth * outHeight) { index ->
                val x = index % outWidth
                convolve(coefficients, index / outWidth) { y -> source[y * currentWidth + x] }
            }
        }
        return current
    }

    private inline fun convolve(c: Coefficients, out: Int, pixel: (Int) -> Int): Int {
        val start = c.bounds[out * 2]
        val count = c.bounds[out * 2 + 1]
        val offset = out * c.size
        var r = 1 shl (PRECISION_BITS - 1)
        var g = r
        var b = r
        for (k in 0 until count) {
            val p = pixel(start + k)
            val weight = c.kernel[offset + k]
            r += ((p shr 16) and 0xFF) * weight
            g += ((p shr 8) and 0xFF) * weight
            b += (p and 0xFF) * weight
        }
        return (0xFF shl 24) or (clip8(r) shl 16) or (clip8(g) shl 8) or clip8(b)
    }

    private fun clip8(value: Int): Int = (value shr PRECISION_BITS).coerceIn(0, 255)

    private fun coefficients(inSize: Int, outSize: Int): Coefficients {
        val scale = inSize.toDouble() / outSize
        val filterScale = maxOf(scale, 1.0)
        val support = 1.0 * filterScale
        val size = ceil(support).toInt() * 2 + 1
        val bounds = IntArray(outSize * 2)
        val kernel = IntArray(outSize * size)
        val weights = DoubleArray(size)
        for (xx in 0 until outSize) {
            val center = (xx + 0.5) * scale
            val inverse = 1.0 / filterScale
            // C's (int) truncates toward zero, as toInt() does.
            val xmin = maxOf((center - support + 0.5).toInt(), 0)
            val xmax = minOf((center + support + 0.5).toInt(), inSize) - xmin
            var total = 0.0
            for (x in 0 until xmax) {
                val distance = kotlin.math.abs((x + xmin - center + 0.5) * inverse)
                val w = if (distance < 1.0) 1.0 - distance else 0.0
                weights[x] = w
                total += w
            }
            for (x in 0 until xmax) {
                val w = if (total != 0.0) weights[x] / total else weights[x]
                val fixed = w * (1 shl PRECISION_BITS)
                kernel[xx * size + x] = if (w < 0) (-0.5 + fixed).toInt() else (0.5 + fixed).toInt()
            }
            bounds[xx * 2] = xmin
            bounds[xx * 2 + 1] = xmax
        }
        return Coefficients(bounds, kernel, size)
    }
}

/**
 * RF-DETR's object-detection post-processing in `inference-models`
 * (`post_process_object_detection_results`), for one image.
 */
object RfDetrOutput {
    /**
     * The boxes of class [classIndex] scoring above [threshold], in frame
     * pixels, highest confidence first.
     *
     * [boxes] is the `dets` output (`[queries, 4]`, center x, center y,
     * width, height as fractions of the input) and [logits] the `labels`
     * output (`[queries, classes]`). As in the library, only the top
     * `queries` scores across every query and class are considered, and the
     * corners are rounded to whole pixels, half to even.
     */
    fun decode(
        boxes: FloatArray,
        logits: FloatArray,
        classCount: Int,
        classIndex: Int,
        threshold: Double,
        config: RfDetrConfig,
        frameWidth: Int,
        frameHeight: Int,
    ): List<TrackerDetection> {
        val queries = boxes.size / 4
        require(logits.size == queries * classCount) { "Expected ${queries * classCount} logits, got ${logits.size}." }
        val scores = FloatArray(logits.size) { sigmoid(logits[it]) }
        // torch.topk(flat, queries): the highest `queries` of all query/class scores.
        val top = scores.indices.sortedByDescending { scores[it] }.take(queries)
        // inference_size * (1 / scale) in float32, as the tensors are.
        val scaleW = (config.inputWidth.toDouble() / frameWidth).toFloat()
        val scaleH = (config.inputHeight.toDouble() / frameHeight).toFloat()
        return top
            .filter { it % classCount == classIndex && scores[it] > threshold.toFloat() }
            .map { flat ->
                val q = flat / classCount
                val cx = boxes[q * 4]
                val cy = boxes[q * 4 + 1]
                val w = boxes[q * 4 + 2]
                val h = boxes[q * 4 + 3]
                fun corner(value: Float, size: Int, scale: Float) = Math.rint(((value * size) / scale).toDouble())
                TrackerDetection(
                    PixelBox(
                        corner(cx - 0.5f * w, config.inputWidth, scaleW),
                        corner(cy - 0.5f * h, config.inputHeight, scaleH),
                        corner(cx + 0.5f * w, config.inputWidth, scaleW),
                        corner(cy + 0.5f * h, config.inputHeight, scaleH),
                    ),
                    scores[flat].toDouble(),
                )
            }
    }

    private fun sigmoid(x: Float): Float = (1.0 / (1.0 + exp(-x.toDouble()))).toFloat()
}
