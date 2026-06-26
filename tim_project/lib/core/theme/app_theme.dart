// ============================================================
// lib/core/theme/app_theme.dart
// Dark-mode-first Material 3 theme for T.I.M.
// Palette: deep charcoal base + electric blue accent (Gemini-style).
// ============================================================

import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  // ---- Palette ----------------------------------------------------
  static const Color _bg = Color(0xFF0F1115);
  static const Color _surface = Color(0xFF171A21);
  static const Color _surfaceVariant = Color(0xFF1F232C);
  static const Color _primary = Color(0xFF8AB4F8);
  static const Color _onPrimary = Color(0xFF06111F);
  static const Color _accent = Color(0xFFE8F0FE);
  static const Color _muted = Color(0xFF9AA0A6);
  static const Color _danger = Color(0xFFF28B82);
  static const Color _success = Color(0xFF81C995);
  static const Color _warning = Color(0xFFFDD663);

  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: _primary,
      brightness: Brightness.dark,
      primary: _primary,
      onPrimary: _onPrimary,
      surface: _surface,
      onSurface: _accent,
      error: _danger,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: _bg,
      canvasColor: _bg,
      dividerColor: _surfaceVariant,
      textTheme: Typography.whiteCupertino.copyWith(
        bodyLarge: const TextStyle(color: _accent, fontSize: 16),
        bodyMedium: const TextStyle(color: _accent, fontSize: 14),
        titleLarge: const TextStyle(
          color: _accent,
          fontSize: 22,
          fontWeight: FontWeight.w600,
        ),
        labelSmall: const TextStyle(color: _muted, fontSize: 12),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: _bg,
        foregroundColor: _accent,
        elevation: 0,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _surfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: _primary,
          foregroundColor: _onPrimary,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: _surface,
        indicatorColor: _primary.withValues(alpha: 0.15),
        selectedIconTheme: const IconThemeData(color: _primary),
        unselectedIconTheme: const IconThemeData(color: _muted),
      ),
      // Live Call View helper colours.
      extensions: const [
        TimPalette(
          bg: _bg,
          surface: _surface,
          primary: _primary,
          accent: _accent,
          muted: _muted,
          danger: _danger,
          success: _success,
          warning: _warning,
        ),
      ],
    );
  }
}

/// Semantic palette exposed as a ThemeExtension so the Live Call View
/// and the waveform widget can pick colours without hardcoding hex.
@immutable
class TimPalette extends ThemeExtension<TimPalette> {
  const TimPalette({
    required this.bg,
    required this.surface,
    required this.primary,
    required this.accent,
    required this.muted,
    required this.danger,
    required this.success,
    required this.warning,
  });

  final Color bg;
  final Color surface;
  final Color primary;
  final Color accent;
  final Color muted;
  final Color danger;
  final Color success;
  final Color warning;

  @override
  TimPalette copyWith({
    Color? bg, Color? surface, Color? primary, Color? accent,
    Color? muted, Color? danger, Color? success, Color? warning,
  }) => TimPalette(
    bg: bg ?? this.bg,
    surface: surface ?? this.surface,
    primary: primary ?? this.primary,
    accent: accent ?? this.accent,
    muted: muted ?? this.muted,
    danger: danger ?? this.danger,
    success: success ?? this.success,
    warning: warning ?? this.warning,
  );

  @override
  TimPalette lerp(ThemeExtension<TimPalette>? other, double t) {
    if (other is! TimPalette) return this;
    return TimPalette(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      primary: Color.lerp(primary, other.primary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
    );
  }
}
