import 'package:flutter/material.dart';

/// P1 design tokens (documented in FRONTEND_SPEC "Visual direction"):
/// charcoal surfaces, warm white text, one coral accent for the selected
/// option and the primary action.
abstract final class AppColors {
  static const background = Color(0xFF1C1C1C);
  static const surface = Color(0xFF262525);
  static const border = Color(0x1FFFFFFF);
  static const text = Color(0xFFF5EFE8);
  static const textSoft = Color(0xFFD9D1C9);
  static const textMuted = Color(0xFFA39B93);
  static const accent = Color(0xFFFF5046);
  // The small star beside the TMDB rating; understated, not a second accent.
  static const rating = Color(0xFFE5B23A);
}

abstract final class AppRadii {
  static const chip = 16.0;
  static const button = 18.0;
}

/// Jost: a geometric sans whose Medium titles and Book metadata give the
/// quiet, poster-led hierarchy of the reference without extra decoration.
/// Weights: 500 headings, 400 body and metadata, 700 primary buttons; 300 only for
/// the large placeholder title (thin strokes lose contrast when small).
abstract final class AppTheme {
  static const _family = 'Jost';

  static const _textTheme = TextTheme(
    headlineMedium: TextStyle(
      fontSize: 30,
      fontWeight: FontWeight.w500,
      height: 1.15,
      letterSpacing: -0.3,
    ),
    titleLarge: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.2,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      height: 1.3,
    ),
    bodyLarge: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w400,
      height: 1.45,
    ),
    bodyMedium: TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w400,
      height: 1.4,
    ),
    labelLarge: TextStyle(
      fontSize: 17,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.2,
    ),
    labelMedium: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      letterSpacing: 0.3,
    ),
  );

  static final ThemeData dark = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: _family,
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.accent,
      onPrimary: Colors.white,
      surface: AppColors.surface,
      onSurface: AppColors.text,
      outline: AppColors.border,
    ),
    textTheme: _textTheme.apply(
      fontFamily: _family,
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
    ),
    dialogTheme: const DialogThemeData(backgroundColor: AppColors.surface),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.surface,
      contentTextStyle: TextStyle(
        fontFamily: _family,
        color: AppColors.text,
        fontSize: 15,
        height: 1.4,
      ),
    ),
  );
}
