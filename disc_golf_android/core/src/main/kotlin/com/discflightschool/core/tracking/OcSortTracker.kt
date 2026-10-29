package com.discflightschool.core.tracking

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** A box in pixels, corner to corner. */
data class PixelBox(val x1: Double, val y1: Double, val x2: Double, val y2: Double) {
    val centerX: Double get() = (x1 + x2) / 2.0
    val centerY: Double get() = (y1 + y2) / 2.0
}

/** One detection handed to [OcSortTracker.update]. */
data class TrackerDetection(val box: PixelBox, val confidence: Double)

/**
 * The settings of the Roboflow Workflow's `roboflow_core/trackers_ocsort@v1`
 * step. The defaults are the values the disc-flight Workflow uses, not the
 * library's own defaults.
 */
data class OcSortSettings(
    val lostTrackBuffer: Int = 30,
    val minimumConsecutiveFrames: Int = 1,
    val minimumIouThreshold: Double = 0.01,
    val directionConsistencyWeight: Double = 0.4,
    val highConfidenceThreshold: Double = 0.15,
    val deltaT: Int = 2,
)

/**
 * OC-SORT, ported from Roboflow's `trackers` package 2.4.0
 * (`trackers.core.ocsort`, Apache 2.0), the version the Workflow block runs.
 *
 * The Workflow block creates the tracker with the video's frame rate and
 * calls `update` once per frame with no timestamp, so this keeps only the
 * fixed-rate path and the center-scale-ratio Kalman state, which are what
 * that call uses. The block then drops the detections whose tracker id is
 * -1; [update] returns only the ones it keeps.
 */
class OcSortTracker(
    fps: Double,
    private val settings: OcSortSettings = OcSortSettings(),
) {
    // int(frame_rate / 30.0 * lost_track_buffer), truncated as Python's int() does.
    private val maximumFramesWithoutUpdate = (fps / 30.0 * settings.lostTrackBuffer).toInt()
    private val tracks = mutableListOf<Tracklet>()
    private var frameCount = 0
    private var nextTrackerId = 0

    /** A detection the tracker matched to a track, by its index in the list given to [update]. */
    data class Tracked(val detectionIndex: Int, val trackerId: Int)

    /**
     * Run one frame. Returns the detections the Workflow's `tracked_disc`
     * output would hold for it: those with a tracker id, in the order the
     * library returns them.
     */
    fun update(detections: List<TrackerDetection>): List<Tracked> {
        if (tracks.isEmpty() && detections.isEmpty()) return emptyList()
        // Indices into `detections` of the ones at or above the threshold.
        val kept = detections.indices.filter { detections[it].confidence >= settings.highConfidenceThreshold }
        val boxes = kept.map { detections[it].box }
        val confidences = kept.map { detections[it].confidence }
        val out = mutableListOf<Tracked>()

        for (track in tracks) track.predict()
        val predicted = tracks.map { it.stateBox() }
        val iou = iouMatrix(predicted, boxes)
        val direction = directionConsistency(boxes, confidences)
        val (matched, unmatchedTracks, unmatchedDetections) = associate(iou, direction, boxes.size)

        for ((row, col) in matched) {
            tracks[row].update(boxes[col])
            out += Tracked(kept[col], tracks[row].resolveTrackerId())
        }

        val spawn: List<Int>
        if (unmatchedDetections.isNotEmpty() && unmatchedTracks.isNotEmpty()) {
            // Second chance (OCR): match what is left against each track's last real observation.
            val ocrIou = iouMatrix(unmatchedTracks.map { tracks[it].lastObservation }, unmatchedDetections.map { boxes[it] })
            val zeros = Array(ocrIou.size) { DoubleArray(unmatchedDetections.size) }
            val (ocrMatched, _, ocrUnmatchedDetections) = associate(ocrIou, zeros, unmatchedDetections.size)
            for ((ocrRow, ocrCol) in ocrMatched) {
                val track = tracks[unmatchedTracks[ocrRow]]
                val detection = unmatchedDetections[ocrCol]
                track.update(boxes[detection])
                out += Tracked(kept[detection], track.resolveTrackerId())
            }
            spawn = ocrUnmatchedDetections.map { unmatchedDetections[it] }
        } else {
            spawn = unmatchedDetections
        }
        tracks.removeAll { it.timeSinceUpdate > maximumFramesWithoutUpdate }
        // A new track's detection is returned with id -1, which the Workflow drops.
        for (detection in spawn) tracks += Tracklet(boxes[detection], settings.deltaT)

        frameCount++
        return out.filter { it.trackerId != -1 }
    }

    private fun Tracklet.resolveTrackerId(): Int {
        val mature = consecutiveUpdates >= settings.minimumConsecutiveFrames
        val eligible = if (frameCount <= settings.minimumConsecutiveFrames) timeSinceUpdate == 0 else mature
        if (!eligible) return -1
        if (trackerId == -1) trackerId = nextTrackerId++
        return trackerId
    }

    private data class Association(
        val matched: List<Pair<Int, Int>>,
        val unmatchedTracks: List<Int>,
        val unmatchedDetections: List<Int>,
    )

    /** [cols] is the detection count, which an empty [iou] (no tracks yet) cannot carry. */
    private fun associate(iou: Array<DoubleArray>, direction: Array<DoubleArray>, cols: Int): Association {
        val rows = iou.size
        val matched = mutableListOf<Pair<Int, Int>>()
        val unmatchedTracks = (0 until rows).toMutableSet()
        val unmatchedDetections = (0 until cols).toMutableSet()
        if (rows > 0 && cols > 0) {
            val cost = Array(rows) { r ->
                DoubleArray(cols) { c -> iou[r][c] + settings.directionConsistencyWeight * direction[r][c] }
            }
            for ((row, col) in LinearAssignment.maximize(cost)) {
                if (iou[row][col] >= settings.minimumIouThreshold) {
                    matched += row to col
                    unmatchedTracks -= row
                    unmatchedDetections -= col
                }
            }
        }
        return Association(matched, unmatchedTracks.sorted(), unmatchedDetections.sorted())
    }

    /** OCM: how well each detection lies along each track's recent direction of travel. */
    private fun directionConsistency(boxes: List<PixelBox>, confidences: List<Double>): Array<DoubleArray> =
        Array(tracks.size) { t ->
            val track = tracks[t]
            val velocity = track.velocity
            val reference = track.kPreviousObservation() ?: track.lastObservation
            DoubleArray(boxes.size) { d ->
                if (velocity == null) return@DoubleArray 0.0
                val dx = boxes[d].centerX - reference.centerX
                val dy = boxes[d].centerY - reference.centerY
                val norm = sqrt(dx * dx + dy * dy) + 1e-6
                val cos = (velocity[1] * (dx / norm) + velocity[0] * (dy / norm)).coerceIn(-1.0, 1.0)
                // The library stores this matrix as float32 before scaling by confidence.
                val cost = ((PI / 2.0 - abs(acos(cos))) / PI).toFloat()
                (cost * confidences[d]).toFloat().toDouble()
            }
        }

    internal companion object {
        /** IoU of every box in [a] with every box in [b], as `supervision.box_iou_batch` computes it. */
        fun iouMatrix(a: List<PixelBox>, b: List<PixelBox>): Array<DoubleArray> = Array(a.size) { i ->
            DoubleArray(b.size) { j -> iou(a[i], b[j]) }
        }

        fun iou(a: PixelBox, b: PixelBox): Double {
            val areaA = (a.x2 - a.x1) * (a.y2 - a.y1)
            val areaB = (b.x2 - b.x1) * (b.y2 - b.y1)
            val inter = max(0.0, min(a.x2, b.x2) - max(a.x1, b.x1)) * max(0.0, min(a.y2, b.y2) - max(a.y1, b.y1))
            val value = inter / (areaA + areaB - inter)
            // A degenerate box gives NaN, which scipy's solver would reject; count it as no overlap.
            return if (value.isFinite()) value else 0.0
        }
    }
}

/** One track: an `OCSORTTracklet` with its center-scale-ratio Kalman filter. */
private class Tracklet(initial: PixelBox, private val deltaT: Int) {
    var age = 0
    var trackerId = -1
    var timeSinceUpdate = 0
    var consecutiveUpdates = 0
    var lastObservation: PixelBox = initial
    /** Normalized `[dy, dx]` from the observation [deltaT] frames back to the latest one. */
    var velocity: DoubleArray? = null
    private val observations = HashMap<Int, PixelBox>()
    private val kf = KalmanFilter.forBox(initial)
    private var frozen: KalmanFilter? = null
    private var observed = true

    fun predict(): PixelBox {
        // Freeze on the first miss, so the re-update (ORU) can start from here.
        if (observed && timeSinceUpdate > 0) {
            frozen = kf.copy()
            observed = false
        }
        // Stop the scale velocity from driving the area negative.
        if (kf.x[6] + kf.x[2] <= 0) kf.x[6] = 0.0
        kf.predict()
        age++
        if (timeSinceUpdate > 0) consecutiveUpdates = 0
        timeSinceUpdate++
        return stateBox()
    }

    fun update(box: PixelBox) {
        kPreviousObservation()?.let { previous ->
            val dx = box.centerX - previous.centerX
            val dy = box.centerY - previous.centerY
            val norm = sqrt(dy * dy + dx * dx) + 1e-6
            velocity = doubleArrayOf(dy / norm, dx / norm)
        }
        frozen?.let { if (!observed) reUpdate(it, box) }
        kf.update(toMeasurement(box))
        observed = true
        timeSinceUpdate = 0
        consecutiveUpdates++
        lastObservation = box
        observations[age] = box
    }

    /** ORU: restore the frozen filter and walk it along a straight line to [box]. */
    private fun reUpdate(saved: KalmanFilter, box: PixelBox) {
        kf.restore(saved)
        val gap = timeSinceUpdate
        val (x1, y1, s1, r1) = toMeasurement(lastObservation)
        val (x2, y2, s2, r2) = toMeasurement(box)
        val w1 = sqrt(s1 * r1)
        val h1 = sqrt(s1 / r1)
        val w2 = sqrt(s2 * r2)
        val h2 = sqrt(s2 / r2)
        for (i in 0 until gap) {
            val f = (i + 1).toDouble()
            val w = w1 + f * (w2 - w1) / gap
            val h = h1 + f * (h2 - h1) / gap
            kf.update(doubleArrayOf(x1 + f * (x2 - x1) / gap, y1 + f * (y2 - y1) / gap, w * h, w / h))
            if (i < gap - 1) kf.predict()
        }
        frozen = null
    }

    fun kPreviousObservation(): PixelBox? {
        if (observations.isEmpty()) return null
        for (i in 0 until deltaT) {
            observations[age - (deltaT - i)]?.let { return it }
        }
        return observations[observations.keys.max()]
    }

    fun stateBox(): PixelBox {
        val w = sqrt(kf.x[2] * kf.x[3])
        val h = kf.x[2] / w
        return PixelBox(kf.x[0] - w / 2, kf.x[1] - h / 2, kf.x[0] + w / 2, kf.x[1] + h / 2)
    }

    companion object {
        /** `[center x, center y, area, width / height]`. */
        fun toMeasurement(box: PixelBox): DoubleArray {
            val w = box.x2 - box.x1
            val h = box.y2 - box.y1
            return doubleArrayOf(box.x1 + w * 0.5, box.y1 + h * 0.5, w * h, w / (h + 1e-6))
        }
    }
}

/**
 * The 7-state constant-velocity filter of `XCYCSRStateEstimator`, with the
 * noise OC-SORT configures: `[x, y, s, r, vx, vy, vs]`, measured as `[x, y, s, r]`.
 */
internal class KalmanFilter private constructor(
    val x: DoubleArray,
    private var p: Array<DoubleArray>,
) {
    fun copy() = KalmanFilter(x.copyOf(), p.map { it.copyOf() }.toTypedArray())

    fun restore(other: KalmanFilter) {
        other.x.copyInto(x)
        p = other.p.map { it.copyOf() }.toTypedArray()
    }

    fun predict() {
        val next = x.copyOf()
        for (i in 0 until 3) next[i] = x[i] + x[i + 4]
        next.copyInto(x)
        p = add(multiply(multiply(F, p), transpose(F)), Q)
    }

    fun update(z: DoubleArray) {
        // H selects the first four states, so H·x, P·Hᵀ and H·P·Hᵀ are slices.
        val innovation = DoubleArray(DIM_Z) { z[it] - x[it] }
        val pht = Array(DIM_X) { r -> DoubleArray(DIM_Z) { c -> p[r][c] } }
        val s = Array(DIM_Z) { r -> DoubleArray(DIM_Z) { c -> pht[r][c] + R[r][c] } }
        val gain = multiply(pht, invert(s))
        for (r in 0 until DIM_X) {
            var sum = 0.0
            for (c in 0 until DIM_Z) sum += gain[r][c] * innovation[c]
            x[r] += sum
        }
        // Joseph form, as the library computes it.
        val iKh = Array(DIM_X) { r -> DoubleArray(DIM_X) { c -> (if (r == c) 1.0 else 0.0) - (if (c < DIM_Z) gain[r][c] else 0.0) } }
        p = add(multiply(multiply(iKh, p), transpose(iKh)), multiply(multiply(gain, R), transpose(gain)))
    }

    companion object {
        private const val DIM_X = 7
        private const val DIM_Z = 4

        private val F = Array(DIM_X) { r -> DoubleArray(DIM_X) { c -> if (r == c || (r < 3 && c == r + 4)) 1.0 else 0.0 } }

        // OCSORTTracklet._configure_noise on identity matrices.
        private val R = Array(DIM_Z) { r -> DoubleArray(DIM_Z) { c -> if (r != c) 0.0 else if (r >= 2) 10.0 else 1.0 } }
        private val Q = Array(DIM_X) { r -> DoubleArray(DIM_X) { c -> if (r != c) 0.0 else if (r == 6) 1e-4 else if (r >= 4) 0.01 else 1.0 } }

        fun forBox(box: PixelBox): KalmanFilter {
            val x = DoubleArray(DIM_X)
            Tracklet.toMeasurement(box).copyInto(x)
            val p = Array(DIM_X) { r -> DoubleArray(DIM_X) { c -> if (r != c) 0.0 else if (r >= 4) 10_000.0 else 10.0 } }
            return KalmanFilter(x, p)
        }

        private fun multiply(a: Array<DoubleArray>, b: Array<DoubleArray>): Array<DoubleArray> {
            val inner = b.size
            return Array(a.size) { r ->
                DoubleArray(b[0].size) { c ->
                    var sum = 0.0
                    for (k in 0 until inner) sum += a[r][k] * b[k][c]
                    sum
                }
            }
        }

        private fun transpose(a: Array<DoubleArray>) = Array(a[0].size) { r -> DoubleArray(a.size) { c -> a[c][r] } }

        private fun add(a: Array<DoubleArray>, b: Array<DoubleArray>) =
            Array(a.size) { r -> DoubleArray(a[0].size) { c -> a[r][c] + b[r][c] } }

        /** Gauss-Jordan inverse with partial pivoting. */
        private fun invert(m: Array<DoubleArray>): Array<DoubleArray> {
            val n = m.size
            val a = Array(n) { r -> DoubleArray(2 * n) { c -> if (c < n) m[r][c] else if (c - n == r) 1.0 else 0.0 } }
            for (col in 0 until n) {
                val pivot = (col until n).maxBy { abs(a[it][col]) }
                val swap = a[col]; a[col] = a[pivot]; a[pivot] = swap
                val scale = a[col][col]
                for (c in 0 until 2 * n) a[col][c] /= scale
                for (r in 0 until n) {
                    if (r == col) continue
                    val factor = a[r][col]
                    if (factor != 0.0) for (c in 0 until 2 * n) a[r][c] -= factor * a[col][c]
                }
            }
            return Array(n) { r -> DoubleArray(n) { c -> a[r][c + n] } }
        }
    }
}

/**
 * `scipy.optimize.linear_sum_assignment`: the shortest augmenting path
 * method (Crouse, 2016) that scipy implements, ported with its tie-breaking
 * so the tracker picks the same pairs scipy would.
 */
internal object LinearAssignment {
    /** The `(row, column)` pairs that maximize the total of [cost], ordered by row. */
    fun maximize(cost: Array<DoubleArray>): List<Pair<Int, Int>> {
        val rows = cost.size
        if (rows == 0 || cost[0].isEmpty()) return emptyList()
        val columns = cost[0].size
        val transpose = columns < rows
        val nr = if (transpose) columns else rows
        val nc = if (transpose) rows else columns
        // Minimize the negated (and, when wider than tall, transposed) matrix.
        val c = Array(nr) { i -> DoubleArray(nc) { j -> -(if (transpose) cost[j][i] else cost[i][j]) } }

        val u = DoubleArray(nr)
        val v = DoubleArray(nc)
        val shortest = DoubleArray(nc)
        val path = IntArray(nc) { -1 }
        val col4row = IntArray(nr) { -1 }
        val row4col = IntArray(nc) { -1 }
        val sr = BooleanArray(nr)
        val sc = BooleanArray(nc)
        val remaining = IntArray(nc)

        for (curRow in 0 until nr) {
            var minVal = 0.0
            var remainingCount = nc
            for (it in 0 until nc) remaining[it] = nc - it - 1
            sr.fill(false)
            sc.fill(false)
            shortest.fill(Double.POSITIVE_INFINITY)
            var sink = -1
            var i = curRow
            while (sink == -1) {
                var index = -1
                var lowest = Double.POSITIVE_INFINITY
                sr[i] = true
                for (it in 0 until remainingCount) {
                    val j = remaining[it]
                    val r = minVal + c[i][j] - u[i] - v[j]
                    if (r < shortest[j]) {
                        path[j] = i
                        shortest[j] = r
                    }
                    if (shortest[j] < lowest || (shortest[j] == lowest && row4col[j] == -1)) {
                        lowest = shortest[j]
                        index = it
                    }
                }
                minVal = lowest
                check(minVal != Double.POSITIVE_INFINITY) { "The cost matrix is infeasible." }
                val j = remaining[index]
                if (row4col[j] == -1) sink = j else i = row4col[j]
                sc[j] = true
                remaining[index] = remaining[--remainingCount]
            }

            u[curRow] += minVal
            for (r in 0 until nr) {
                if (sr[r] && r != curRow) u[r] += minVal - shortest[col4row[r]]
            }
            for (j in 0 until nc) {
                if (sc[j]) v[j] -= minVal - shortest[j]
            }
            var j = sink
            while (true) {
                val r = path[j]
                row4col[j] = r
                val previous = col4row[r]
                col4row[r] = j
                j = previous
                if (r == curRow) break
            }
        }

        return if (transpose) {
            // col4row maps each original column to its row; order the pairs by row.
            col4row.indices.sortedBy { col4row[it] }.map { col4row[it] to it }
        } else {
            (0 until nr).map { it to col4row[it] }
        }
    }
}
