package com.discflightschool.app.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/**
 * The app runs dark at every system setting.
 *
 * Flight paths and pose skeletons are drawn as bright strokes over video, and a
 * light chrome around them washes out the contrast the overlays depend on.
 */
object AppColors {
    val Background = Color(0xFF1A1A2E)
    val Surface = Color(0xFF16213E)
    val TopBar = Color(0xFF0F3460)
    val Accent = Color(0xFF40C4FF)
    val OnSurface = Color(0xFFECEFF1)
    val Muted = Color(0xFF9FA8B5)

    /** Per-feature accents, used on the home cards and section headers. */
    val FlightTracker = Color(0xFF42A5F5)
    val FormCoach = Color(0xFFFFA726)
    // A light tone, so the accent passes 4.5:1 as text on Surface and on its own
    // 20% tint. The wheel keeps its deeper purples, which never carry text.
    val Roulette = Color(0xFFCE93D8)
    val KnowledgeBase = Color(0xFF26A69A)

    /** Status colours shared by score chips, warnings, and quality badges. */
    val Good = Color(0xFF66BB6A)
    val Warning = Color(0xFFFFB74D)
    val Bad = Color(0xFFFF8A80)
}

private val DiscFlightSchoolColorScheme = darkColorScheme(
    primary = AppColors.Accent,
    onPrimary = Color(0xFF00243A),
    primaryContainer = AppColors.TopBar,
    onPrimaryContainer = AppColors.OnSurface,
    secondary = AppColors.FlightTracker,
    onSecondary = Color(0xFF00243A),
    background = AppColors.Background,
    onBackground = AppColors.OnSurface,
    surface = AppColors.Surface,
    onSurface = AppColors.OnSurface,
    surfaceVariant = Color(0xFF1E2A4A),
    onSurfaceVariant = AppColors.Muted,
    error = AppColors.Bad,
    // outline marks the edges people must find (text fields, outlined buttons)
    // and needs 3:1 against surface; outlineVariant is for dividers only.
    outline = Color(0xFF6B7A99),
    outlineVariant = Color(0xFF38455F),
)

@Composable
fun DiscFlightSchoolTheme(
    // Accepted so a preview can force light mode; the scheme is dark either way.
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = DiscFlightSchoolColorScheme,
        typography = Typography(),
        content = content,
    )
}
