package com.discflightschool.app

import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
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
        // The app is dark at every system setting, so the bar icons must be
        // light at every setting too. The default style follows the system
        // theme, which in light mode puts dark icons on the dark top bar.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )

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
                            .consumeWindowInsets(WindowInsets.navigationBars)
                            // Edge-to-edge stops adjustResize from shrinking the
                            // window, so the keyboard inset is applied here, once,
                            // for every screen with a text field.
                            .imePadding(),
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
