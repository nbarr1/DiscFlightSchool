package com.discflightschool.core.detection

/**
 * Writes a decoded frame into the flat float buffer the interpreter expects.
 *
 * The channel order is not a detail that can be assumed: Ultralytics' current
 * LiteRT export traces the PyTorch model directly and produces NCHW, while the
 * legacy onnx2tf export produced NHWC. Getting it wrong does not throw — it
 * feeds the model a scrambled image and quietly detects nothing — so the write
 * pattern is isolated here and tested directly.
 */
object YoloPreprocessor {

    /** The buffer size a square [inputSize] RGB input needs. */
    fun bufferSize(inputSize: Int): Int = inputSize * inputSize * 3

    /**
     * Normalize [pixels] (ARGB, row-major, `inputSize * inputSize` entries) into
     * [out], which is allocated if not supplied and returned either way.
     *
     * Reusing one buffer across frames matters: a 640x640x3 input is over a
     * million floats, and rebuilding it per frame dominated tracking cost over a
     * multi-hundred-frame run. The returned array is owned by the caller that
     * supplied it and is overwritten by the next call.
     */
    fun writeNormalizedInput(
        pixels: IntArray,
        inputSize: Int,
        channelsFirst: Boolean,
        out: FloatArray = FloatArray(bufferSize(inputSize)),
    ): FloatArray {
        val expected = inputSize * inputSize
        require(pixels.size >= expected) {
            "expected at least $expected pixels for a ${inputSize}x$inputSize input, " +
                "got ${pixels.size}"
        }
        require(out.size >= bufferSize(inputSize)) {
            "output buffer of ${out.size} is too small for a ${inputSize}x$inputSize input"
        }

        if (channelsFirst) {
            // NCHW: [1, 3, H, W], channel-planar — all of R, then all of G, then
            // all of B.
            val plane = expected
            for (i in 0 until expected) {
                val pixel = pixels[i]
                out[i] = ((pixel shr 16) and 0xFF) / 255f
                out[plane + i] = ((pixel shr 8) and 0xFF) / 255f
                out[2 * plane + i] = (pixel and 0xFF) / 255f
            }
        } else {
            // NHWC: [1, H, W, 3], pixels interleaved as R, G, B.
            var o = 0
            for (i in 0 until expected) {
                val pixel = pixels[i]
                out[o++] = ((pixel shr 16) and 0xFF) / 255f
                out[o++] = ((pixel shr 8) and 0xFF) / 255f
                out[o++] = (pixel and 0xFF) / 255f
            }
        }

        return out
    }

    /** Pack red, green, and blue channel values into an ARGB pixel. */
    fun argb(red: Int, green: Int, blue: Int): Int =
        (0xFF shl 24) or ((red and 0xFF) shl 16) or ((green and 0xFF) shl 8) or (blue and 0xFF)
}
