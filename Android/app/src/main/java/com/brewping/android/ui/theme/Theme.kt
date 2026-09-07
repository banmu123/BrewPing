package com.brewping.android.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable

private val BrewPingColorScheme = lightColorScheme(
    background = BrewPingBackground,
    surface = BrewPingSurface,
    onSurface = BrewPingOnSurface,
    onSurfaceVariant = BrewPingOnSurfaceVariant,
    primary = BrewPingPrimary,
    onPrimary = BrewPingSurface,
    surfaceVariant = BrewPingSurfaceVariant,
    outline = BrewPingDivider,
)

@Composable
fun BrewPingTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = BrewPingColorScheme,
        typography = BrewPingTypography,
        content = content,
    )
}
