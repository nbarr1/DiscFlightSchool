package com.discflightschool.app.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.discflightschool.core.detection.FlightTrackingResult
import com.discflightschool.core.model.FormAnalysis
import com.discflightschool.core.model.ThrowTypes
import com.discflightschool.core.tracking.TrackerSeedPoint

/**
 * The clip being worked on and everything measured from it.
 *
 * Form Coach and Flight Tracker are each several screens deep — trim, then
 * mark, then analyse, then compare — all operating on one video. Passing a
 * whole analysis or flight path through navigation arguments would mean
 * serializing it at every step; holding it here keeps the routes to plain
 * identifiers and keeps a back-navigation from discarding work.
 *
 * Compose snapshot state, so reading any field in a composable subscribes it to
 * changes.
 */
class WorkbenchState {

    // ── Form Coach ───────────────────────────────────────────────────────

    var formVideoPath by mutableStateOf<String?>(null)
    var proPlayer by mutableStateOf<String?>(null)
    var throwType by mutableStateOf(ThrowTypes.BACKHAND)
    var isLeftHanded by mutableStateOf(false)

    /** The analysed range of the clip, in milliseconds from the start of the file. */
    var analysisStartMs by mutableStateOf(0L)
    var analysisEndMs by mutableStateOf(0L)
    var analysisFrameCount by mutableStateOf(0)

    /** Phase name to the frame index the user marked it at. */
    var phaseFrameIndices by mutableStateOf<Map<String, Int>>(emptyMap())

    var analysis by mutableStateOf<FormAnalysis?>(null)

    /** The selected pro's phase angles, resolved with baseline fallbacks. */
    var proPhaseAngles by mutableStateOf<Map<String, Map<String, Double>>>(emptyMap())

    /** Warnings raised while resolving the pro data, for the analysis screen. */
    var proDataWarnings by mutableStateOf<List<String>>(emptyList())

    fun startFormSession(
        videoPath: String,
        proPlayer: String?,
        throwType: String,
        isLeftHanded: Boolean,
    ) {
        formVideoPath = videoPath
        this.proPlayer = proPlayer
        this.throwType = throwType
        this.isLeftHanded = isLeftHanded
        analysisStartMs = 0
        analysisEndMs = 0
        analysisFrameCount = 0
        phaseFrameIndices = emptyMap()
        analysis = null
        proPhaseAngles = emptyMap()
        proDataWarnings = emptyList()
    }

    // ── Flight Tracker ───────────────────────────────────────────────────

    var flightVideoPath by mutableStateOf<String?>(null)

    /** The trimmed range every tracker frame index is relative to. */
    var flightTrimStartMs by mutableStateOf(0L)
    var flightTrimEndMs by mutableStateOf<Long?>(null)

    var flightResult by mutableStateOf<FlightTrackingResult?>(null)

    /** User-placed keyframes, kept so a converted auto path stays editable. */
    var seedPoints by mutableStateOf<List<TrackerSeedPoint>>(emptyList())

    /** True when the current path came from the detector rather than by hand. */
    var flightWasAutoDetected by mutableStateOf(false)

    fun startFlightSession(videoPath: String) {
        flightVideoPath = videoPath
        flightTrimStartMs = 0
        flightTrimEndMs = null
        flightResult = null
        seedPoints = emptyList()
        flightWasAutoDetected = false
    }
}
