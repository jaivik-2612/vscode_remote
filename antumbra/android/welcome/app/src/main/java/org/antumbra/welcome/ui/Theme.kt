// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/**
 * Antumbra's palette: the Material 3 "tonal spot" dark scheme generated
 * once, offline, from the seed #4d2c9e with material-color-utilities 0.3.0
 * (Apache-2.0); only the resulting values are kept. They are the values of
 * the archived theme (antumbra/config/rootfs/usr/share/antumbra/theme/
 * shell.css), completed with the roles that file did not need. Always dark,
 * like the archived Welcome screen. Text uses the system font (Roboto).
 */
val AntumbraDark = darkColorScheme(
    primary = Color(0xFFCEBDFE),
    onPrimary = Color(0xFF35275D),
    primaryContainer = Color(0xFF4C3E76),
    onPrimaryContainer = Color(0xFFE8DDFF),
    inversePrimary = Color(0xFF64558F),
    secondary = Color(0xFFCBC3DC),
    onSecondary = Color(0xFF332D41),
    secondaryContainer = Color(0xFF494458),
    onSecondaryContainer = Color(0xFFE8DEF8),
    tertiary = Color(0xFFEFB8C9),
    onTertiary = Color(0xFF492532),
    tertiaryContainer = Color(0xFF633B49),
    onTertiaryContainer = Color(0xFFFFD9E3),
    background = Color(0xFF141218),
    onBackground = Color(0xFFE6E1E9),
    surface = Color(0xFF141218),
    onSurface = Color(0xFFE6E1E9),
    surfaceVariant = Color(0xFF48454E),
    onSurfaceVariant = Color(0xFFCAC4CF),
    surfaceTint = Color(0xFFCEBDFE),
    inverseSurface = Color(0xFFE6E1E9),
    inverseOnSurface = Color(0xFF322F35),
    error = Color(0xFFFFB4AB),
    onError = Color(0xFF690005),
    errorContainer = Color(0xFF93000A),
    onErrorContainer = Color(0xFFFFDAD6),
    outline = Color(0xFF948F99),
    outlineVariant = Color(0xFF48454E),
    scrim = Color(0xFF000000),
    surfaceBright = Color(0xFF3B383E),
    surfaceDim = Color(0xFF141218),
    surfaceContainerLowest = Color(0xFF0F0D13),
    surfaceContainerLow = Color(0xFF1C1B20),
    surfaceContainer = Color(0xFF211F24),
    surfaceContainerHigh = Color(0xFF2B292F),
    surfaceContainerHighest = Color(0xFF36343A),
)

@Composable
fun AntumbraTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = AntumbraDark, content = content)
}
