import 'package:flutter/material.dart';

ThemeData buildAstraTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF4EA4F4),
        brightness: Brightness.dark,
      ).copyWith(
        primary: const Color(0xFF4EA4F4),
        secondary: const Color(0xFF61C1FF),
        surface: const Color(0xFF131A24),
        surfaceContainer: const Color(0xFF1B2431),
        outline: const Color(0xFF2C3A4A),
      );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFF0E141D),
    appBarTheme: const AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      backgroundColor: Color(0xFF0E141D),
    ),
    cardTheme: CardThemeData(
      color: const Color(0xFF151F2C),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFF263444)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF1A2534),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF2C3A4A)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF2C3A4A)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF4EA4F4), width: 1.3),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}
