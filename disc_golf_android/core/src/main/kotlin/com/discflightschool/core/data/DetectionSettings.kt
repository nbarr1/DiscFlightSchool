package com.discflightschool.core.data

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The detector's user-tunable sensitivity.
 *
 * Detection quality warnings scale with this value, so it is shared rather than
 * read independently in each place that needs it.
 */
class DetectionSettings(private val store: KeyValueStore) {

    private val _confidenceThreshold = MutableStateFlow(
        (store.getDouble(KEY) ?: DEFAULT_CONFIDENCE_THRESHOLD)
            .coerceIn(MIN_THRESHOLD, MAX_THRESHOLD),
    )
    val confidenceThreshold: StateFlow<Double> = _confidenceThreshold.asStateFlow()

    fun setConfidenceThreshold(value: Double) {
        val clamped = value.coerceIn(MIN_THRESHOLD, MAX_THRESHOLD)
        _confidenceThreshold.value = clamped
        store.putDouble(KEY, clamped)
    }

    companion object {
        const val KEY = "disc_confidence_threshold"
        const val DEFAULT_CONFIDENCE_THRESHOLD = 0.1
        const val MIN_THRESHOLD = 0.01
        const val MAX_THRESHOLD = 0.95
    }
}

/** One-time flags the app reads at startup. */
class AppPreferences(private val store: KeyValueStore) {
    var onboardingComplete: Boolean
        get() = store.getBoolean(ONBOARDING_COMPLETE) ?: false
        set(value) = store.putBoolean(ONBOARDING_COMPLETE, value)

    var isLeftHanded: Boolean
        get() = store.getBoolean(LEFT_HANDED) ?: false
        set(value) = store.putBoolean(LEFT_HANDED, value)

    var preferredThrowType: String
        get() = store.getString(THROW_TYPE) ?: com.discflightschool.core.model.ThrowTypes.BACKHAND
        set(value) = store.putString(THROW_TYPE, value)

    companion object {
        const val ONBOARDING_COMPLETE = "onboarding_complete"
        const val LEFT_HANDED = "is_left_handed"
        const val THROW_TYPE = "preferred_throw_type"
    }
}
