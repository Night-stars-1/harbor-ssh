import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

// Terminal ANSI roles need their own palette: background and foreground must
// switch together, including cursor, selection, and search highlights.
TerminalTheme harborTerminalTheme(ColorScheme colors) {
  final dark = colors.brightness == Brightness.dark;
  return TerminalTheme(
    foreground: colors.onSurface,
    background: colors.surfaceContainerLowest,
    cursor: colors.primary,
    selection: colors.primary.withValues(alpha: dark ? 0.30 : 0.16),
    black: const Color(0xFF1D1B20),
    white: const Color(0xFFE6E1E5),
    brightBlack: dark ? const Color(0xFFAAA5AF) : const Color(0xFF625D67),
    brightWhite: colors.onSurface,
    red: dark ? const Color(0xFFFFB4AB) : const Color(0xFFB3261E),
    green: dark ? const Color(0xFF8ED8AD) : const Color(0xFF21683E),
    yellow: dark ? const Color(0xFFE9C46A) : const Color(0xFF795900),
    blue: dark ? const Color(0xFFAAC7FF) : const Color(0xFF2459A6),
    magenta: dark ? const Color(0xFFEAB2EF) : const Color(0xFF8B3A91),
    cyan: dark ? const Color(0xFF80D5DE) : const Color(0xFF006874),
    brightRed: dark ? const Color(0xFFFFDAD6) : const Color(0xFF93000A),
    brightGreen: dark ? const Color(0xFFB1F1C8) : const Color(0xFF00522C),
    brightYellow: dark ? const Color(0xFFFFDEA1) : const Color(0xFF624900),
    brightBlue: dark ? const Color(0xFFD6E3FF) : const Color(0xFF003F87),
    brightMagenta: dark ? const Color(0xFFFDD7FF) : const Color(0xFF713078),
    brightCyan: dark ? const Color(0xFFAAEDF4) : const Color(0xFF00515A),
    searchHitBackground: colors.tertiaryContainer,
    searchHitBackgroundCurrent: colors.tertiaryContainer,
    searchHitForeground: colors.onTertiaryContainer,
  );
}
