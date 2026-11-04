package com.discflightschool.core.data

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
