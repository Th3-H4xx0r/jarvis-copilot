import 'package:flutter/material.dart';

/// JarvisCopilot dark theme — mirrors the webui's gold-on-deep-navy
/// palette. We deliberately go dark-only on mobile: the webui defaults
/// to dark on first-load too, and a mid-flow light/dark flicker between
/// native pages and embedded webview tabs reads as a bug.
class JcTheme {
  static const Color bg = Color(0xFF0A0E1A);
  static const Color surface = Color(0xFF14203A);
  static const Color surfaceAlt = Color(0xFF1B2A47);
  static const Color border = Color(0x1AFFFFFF);
  static const Color text = Color(0xFFE9EEF8);
  static const Color muted = Color(0xFF8898B5);
  static const Color accent = Color(0xFFF0B341);        // gold
  static const Color accentAlt = Color(0xFFE0552B);     // amber-red (gradient end)
  static const Color blue = Color(0xFF7CB9FF);
  static const Color success = Color(0xFF7AE597);
  static const Color danger = Color(0xFFFF7A8A);

  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accent, accentAlt],
  );

  static ThemeData build() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(
        primary: accent,
        secondary: accentAlt,
        surface: surface,
        onPrimary: Colors.black,
        onSurface: text,
        error: danger,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        foregroundColor: text,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: text,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: surface,
        selectedItemColor: accent,
        unselectedItemColor: muted,
        type: BottomNavigationBarType.fixed,
        showUnselectedLabels: true,
        selectedLabelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        unselectedLabelStyle: TextStyle(fontSize: 11),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: border, width: 1),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceAlt,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: accent, width: 1.4),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          foregroundColor: Colors.black,
          backgroundColor: accent,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accent),
      ),
      dividerTheme: const DividerThemeData(color: border, thickness: 1, space: 1),
    );
  }
}
