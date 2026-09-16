package com.discflightschool.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import com.discflightschool.app.ui.AppNavHost
import com.discflightschool.app.ui.theme.DiscFlightSchoolTheme

/**
 * The [AppContainer] for the current process.
 *
 * A composition local rather than a parameter on every screen: the container is
 * a process singleton, and threading it through two dozen composables would add
 * noise to every signature without making the lifetime any clearer.
 */
val LocalAppContainer = staticCompositionLocalOf<AppContainer> {
    error("No AppContainer provided")
}

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val container = (application as DiscFlightSchoolApplication).container

        setContent {
            DiscFlightSchoolTheme {
                CompositionLocalProvider(LocalAppContainer provides container) {
                    Surface(
                        modifier = Modifier
                            .fillMaxSize()
                            // The top bars handle their own inset; the gesture bar
                            // would otherwise sit on top of scrolling content.
                            .windowInsetsPadding(WindowInsets.navigationBars)
                            .consumeWindowInsets(WindowInsets.navigationBars),
                    ) {
                        AppNavHost(
                            startOnHome = container.appPreferences.onboardingComplete,
                        )
                    }
                }
            }
        }
    }
}
