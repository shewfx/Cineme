import 'package:flutter/material.dart';

/// Calm cinema palette: near-black surfaces, warm light text, one restrained accent.
/// Final design tokens are chosen and documented in P1.
abstract final class AppTheme {
  static const _background = Color(0xFF0E0D0C);
  static const _surface = Color(0xFF1A1816);
  static const _text = Color(0xFFF2E8DC);
  static const _accent = Color(0xFFD9A441);

  static final ThemeData dark = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: _background,
    colorScheme: const ColorScheme.dark(
      primary: _accent,
      onPrimary: _background,
      surface: _surface,
      onSurface: _text,
    ),
  );
}
