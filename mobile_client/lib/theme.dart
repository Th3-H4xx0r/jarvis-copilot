import 'package:flutter/material.dart';

/// JarvisCopilot mobile theme — "dark glass + iridescent".
///
/// Near-black canvas with frosted-glass surfaces and a cyan→violet→pink
/// iridescent brand gradient (replaces the old gold). Dark-only by design:
/// the embedded webui tabs render dark, so a light/dark flip would flicker.
///
/// The legacy token NAMES (accent, surface, …) are kept and retargeted to the
/// new palette so screens that reference them pick up the new look for free;
/// glass-specific tokens (glassFill, glassBorder, bgTop) are new.
class JcTheme {
  // Canvas
  static const Color bg = Color(0xFF070710);
  static const Color bgTop = Color(0xFF0E0E18);

  // Glass surfaces — translucent, ONLY for elements layered over the gradient
  // backdrop (cards, nav bar, pills). Use GlassCard / glassFill explicitly.
  static const Color glassFill = Color(0x14FFFFFF);      // white @ ~8%
  static const Color glassBorder = Color(0x1AFFFFFF);    // white @ ~10%
  // SOLID surfaces — for backgrounds that must be opaque (drawers, dialogs,
  // bottom sheets, message bubbles). These were briefly aliased to glass during
  // the revamp, which made drawers/dialogs bleed the content behind them.
  static const Color surface = Color(0xFF14141F);        // solid panel
  static const Color surfaceAlt = Color(0xFF1C1C2A);     // solid, slightly lighter
  static const Color border = glassBorder;

  // Text
  static const Color text = Color(0xFFEDF0F8);
  static const Color muted = Color(0xFF8A93A8);

  // Brand — iridescent. `accent` (legacy primary) = the violet midpoint so
  // single-color uses read on-brand; gradient available via brandGradient.
  static const Color accent = Color(0xFF8A7CFF);         // violet
  static const Color accentAlt = Color(0xFFFF6FD8);      // pink
  static const Color cyan = Color(0xFF46E0E0);
  static const Color blue = Color(0xFF7CB9FF);
  static const Color success = Color(0xFF5BE5A0);
  static const Color danger = Color(0xFFFF6B7E);

  /// Iridescent brand gradient: cyan → violet → pink.
  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [cyan, accent, accentAlt],
  );

  /// App-wide geometric sans = Inter, BUNDLED as an asset (see assets/fonts/ +
  /// pubspec `fonts:`). Bundling (not runtime-fetching) is what actually makes
  /// it render — google_fonts silently falls back to the system font if it
  /// can't fetch over the network. `fontFamily` is set on the ThemeData below;
  /// here we just tune sizes/weights/tracking.
  static const String fontFamily = 'Inter';

  static TextTheme _textTheme(TextTheme base) => base.copyWith(
        displaySmall: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.5, color: text),
        titleLarge: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: -0.2, color: text),
        titleMedium: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: text),
        bodyLarge: const TextStyle(fontSize: 15, fontWeight: FontWeight.w400, height: 1.45, color: text),
        bodyMedium: const TextStyle(fontSize: 14, fontWeight: FontWeight.w400, height: 1.45, color: text),
        labelLarge: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.2),
        bodySmall: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: muted),
      );

  static ThemeData build() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      // Apply Inter to the whole text theme (copyWith has no fontFamily param;
      // .apply propagates the family to every text style).
      textTheme: _textTheme(base.textTheme).apply(fontFamily: fontFamily),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: fontFamily),
      colorScheme: const ColorScheme.dark(
        primary: accent,
        secondary: cyan,
        surface: bg,
        onPrimary: Colors.white,
        onSurface: text,
        error: danger,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          color: text,
        ),
      ),
      cardTheme: CardThemeData(
        color: glassFill,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: glassBorder, width: 1),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: glassFill,
        hintStyle: const TextStyle(color: muted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: glassBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: accent, width: 1.4),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: accent,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accent),
      ),
      dividerTheme: const DividerThemeData(color: glassBorder, thickness: 1, space: 1),
    );
  }
}
