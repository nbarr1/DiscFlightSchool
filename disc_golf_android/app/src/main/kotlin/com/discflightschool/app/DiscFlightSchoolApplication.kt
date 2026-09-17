package com.discflightschool.app

import android.app.Application

/** Owns the [AppContainer] for the life of the process. */
class DiscFlightSchoolApplication : Application() {

    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
    }

    override fun onTerminate() {
        // Only called on emulators, but releasing here costs nothing and makes
        // the ownership of the native resources explicit.
        container.shutdown()
        super.onTerminate()
    }
}
