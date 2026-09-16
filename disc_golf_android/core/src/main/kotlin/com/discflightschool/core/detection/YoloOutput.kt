package com.discflightschool.core.detection

/**
 * Parsing for the ultralytics anchor-free `Detect` head output, and the input
 * geometry decisions that have to agree with it.
 *
 * The format is identical for YOLOv8 and YOLO11 exports: `[1, 4+nc, N]`
 * transposed or `[1, N, 4+nc]` standard, with coordinates normalized 0-1 by the
 * TFLite export. Verified against the ultralytics head implementation — no
 * version branching exists there — rather than assumed.
 */
object YoloOutput {

    /**
     * Fallback input size used only until a model is loaded. The real value is
     * read from the interpreter's input tensor at load time: a retrained model
     * is not guaranteed to ship at the same geometry as the bundled default,
     * and nothing resizes the input tensor, so preprocessing must match
     * whatever the model actually expects.
     */
    const val DEFAULT_INPUT_SIZE = 640

    /** The input geometry a loaded model declares. */
    data class InputLayout(
        val size: Int,
        /** True for NCHW `[1,3,H,W]`, false for NHWC `[1,H,W,3]`. */
        val channelsFirst: Boolean,
        /** False when neither layout matched and [size] is a guess. */
        val recognized: Boolean,
    )

    /**
     * Determines the square input size and channel order from a loaded model's
     * input tensor shape.
     *
     * NHWC (`[1,H,W,3]`) and NCHW (`[1,3,H,W]`) are told apart by which
     * dimension after the batch dimension equals 3 — the channel count. This is
     * unambiguous for any real detector: a stride-32 head needs an input of at
     * least 32px, so a dimension of exactly 3 can only ever be the channel axis,
     * never a spatial one. Falls back to the historical NHWC assumption, with
     * `recognized = false`, for a shape that is not 4-D or matches neither
     * pattern — [expectedAnchors] flags it downstream if the guess is wrong.
     */
    fun detectInputLayout(shape: IntArray): InputLayout {
        if (shape.size == 4 && shape[3] == 3) {
            return InputLayout(size = shape[1], channelsFirst = false, recognized = true)
        }
        if (shape.size == 4 && shape[1] == 3) {
            return InputLayout(size = shape[2], channelsFirst = true, recognized = true)
        }
        if (shape.size >= 3 && shape[1] > 0) {
            return InputLayout(size = shape[1], channelsFirst = false, recognized = false)
        }
        return InputLayout(size = DEFAULT_INPUT_SIZE, channelsFirst = false, recognized = false)
    }

    /**
     * The anchor count an ultralytics anchor-free `Detect` head produces for a
     * square [inputSize]: one prediction per cell across the P3/P4/P5 strides
     * (8, 16, 32). 640 gives 80²+40²+20² = 8400; 320 gives 40²+20²+10² = 2100.
     */
    fun expectedAnchors(inputSize: Int): Int {
        var total = 0
        for (stride in intArrayOf(8, 16, 32)) {
            val cells = inputSize / stride
            total += cells * cells
        }
        return total
    }

    /**
     * Normalize a raw model coordinate.
     *
     * Exports that emit pixel coordinates rather than normalized ones are
     * divided by the input size; anything already in 0-1 passes through.
     */
    fun normalizeModelValue(value: Double, inputSize: Int): Double {
        val normalized = if (value > 1.0) value / inputSize else value
        return normalized.coerceIn(0.0, 1.0)
    }

    /**
     * The single best detection above [confidenceThreshold], or null.
     *
     * [output] is the flattened output tensor and [shape] its `[1, d1, d2]`
     * shape. Tie-breaking is a strict `>` against a running best, so the first
     * of equal-confidence candidates wins.
     */
    fun parseBestDetection(
        output: FloatArray,
        shape: IntArray,
        frameIndex: Int,
        fps: Double,
        confidenceThreshold: Double,
        inputSize: Int = DEFAULT_INPUT_SIZE,
    ): DiscDetection? {
        val reader = OutputReader(output, shape)
        var best: DiscDetection? = null
        var bestConfidence = confidenceThreshold
        val timestamp = DiscDetection.timestampFor(frameIndex, fps)

        for (i in 0 until reader.count) {
            val conf = reader.confidenceAt(i)
            if (conf > bestConfidence) {
                bestConfidence = conf
                best = DiscDetection(
                    frameIndex = frameIndex,
                    x = normalizeModelValue(reader.boxAt(i, 0), inputSize),
                    y = normalizeModelValue(reader.boxAt(i, 1), inputSize),
                    width = normalizeModelValue(reader.boxAt(i, 2), inputSize),
                    height = normalizeModelValue(reader.boxAt(i, 3), inputSize),
                    confidence = conf,
                    timestampMs = timestamp,
                )
            }
        }

        return best
    }

    /**
     * Every candidate above [confidenceThreshold], sorted highest-confidence
     * first and capped to [maxCandidates].
     *
     * Used by tracking mode, where the caller needs to pick the candidate
     * consistent with the established track rather than assuming the
     * top-confidence one is the disc.
     */
    fun parseCandidateDetections(
        output: FloatArray,
        shape: IntArray,
        frameIndex: Int,
        fps: Double,
        confidenceThreshold: Double,
        maxCandidates: Int,
        inputSize: Int = DEFAULT_INPUT_SIZE,
    ): List<DiscDetection> {
        val reader = OutputReader(output, shape)
        val candidates = ArrayList<DiscDetection>()
        val timestamp = DiscDetection.timestampFor(frameIndex, fps)

        for (i in 0 until reader.count) {
            val conf = reader.confidenceAt(i)
            if (conf <= confidenceThreshold) continue
            candidates += DiscDetection(
                frameIndex = frameIndex,
                x = normalizeModelValue(reader.boxAt(i, 0), inputSize),
                y = normalizeModelValue(reader.boxAt(i, 1), inputSize),
                width = normalizeModelValue(reader.boxAt(i, 2), inputSize),
                height = normalizeModelValue(reader.boxAt(i, 3), inputSize),
                confidence = conf,
                timestampMs = timestamp,
            )
        }

        candidates.sortByDescending { it.confidence }
        return if (candidates.size > maxCandidates) candidates.subList(0, maxCandidates) else candidates
    }

    /**
     * Reads a flattened `[1, d1, d2]` output tensor in either the transposed
     * `[1, 4+nc, N]` layout ultralytics TFLite exports emit, or the standard
     * `[1, N, 4+nc]` layout.
     */
    private class OutputReader(private val output: FloatArray, shape: IntArray) {
        private val dim1 = shape[1]
        private val dim2 = shape[2]
        private val transposed = dim1 == 5 || dim1 == 6
        private val channels = if (transposed) dim1 else dim2

        val count: Int = if (transposed) dim2 else dim1

        fun boxAt(index: Int, coordinate: Int): Double =
            if (transposed) {
                output[coordinate * dim2 + index].toDouble()
            } else {
                output[index * dim2 + coordinate].toDouble()
            }

        fun confidenceAt(index: Int): Double = if (transposed) {
            val objectness = output[4 * dim2 + index].toDouble()
            if (channels == 5) objectness else objectness * output[5 * dim2 + index].toDouble()
        } else {
            val objectness = output[index * dim2 + 4].toDouble()
            if (channels >= 6) objectness * output[index * dim2 + 5].toDouble() else objectness
        }
    }
}
