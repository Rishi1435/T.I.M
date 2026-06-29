// ============================================================
// lib/core/theme/app_theme.dart
// Dark-mode-first Material 3 theme for T.I.M.
// Palette: deep charcoal base + electric blue accent (Gemini-style).
// ============================================================

import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  // ---- Palette ----------------------------------------------------
  static const Color _bg = Color(0xFF000000);
  static const Color _bgGlow = Color(0xFF131722);
  static const Color _surface = Color(0xFF1E1F20);
  static const Color _surfaceVariant = Color(0xFF282A2C);
  static const Color _surfaceHover = Color(0xFF333537);
  static const Color _primary = Color(0xFFA8C7FA);
  static const Color _onPrimary = Color(0xFF000000);
  static const Color _accent = Color(0xFFE3E3E3); // text-primary
  static const Color _textSecondary = Color(0xFFC4C7C5);
  static const Color _muted = Color(0xFF8E918F); // text-tertiary
  static const Color _danger = Color(0xFFF28B82);
  static const Color _success = Color(0xFF81C995);
  static const Color _warning = Color(0xFFF28B82);

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
        bodyMedium: const TextStyle(color: _textSecondary, fontSize: 14),
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
          bgGlow: _bgGlow,
          surface: _surface,
          surfaceVariant: _surfaceVariant,
          surfaceHover: _surfaceHover,
          primary: _primary,
          accent: _accent,
          textSecondary: _textSecondary,
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
    required this.bgGlow,
    required this.surface,
    required this.surfaceVariant,
    required this.surfaceHover,
    required this.primary,
    required this.accent,
    required this.textSecondary,
    required this.muted,
    required this.danger,
    required this.success,
    required this.warning,
  });

  final Color bg;
  final Color bgGlow;
  final Color surface;
  final Color surfaceVariant;
  final Color surfaceHover;
  final Color primary;
  final Color accent;
  final Color textSecondary;
  final Color muted;
  final Color danger;
  final Color success;
  final Color warning;

  @override
  TimPalette copyWith({
    Color? bg, Color? bgGlow, Color? surface, Color? surfaceVariant,
    Color? surfaceHover, Color? primary, Color? accent, Color? textSecondary,
    Color? muted, Color? danger, Color? success, Color? warning,
  }) => TimPalette(
    bg: bg ?? this.bg,
    bgGlow: bgGlow ?? this.bgGlow,
    surface: surface ?? this.surface,
    surfaceVariant: surfaceVariant ?? this.surfaceVariant,
    surfaceHover: surfaceHover ?? this.surfaceHover,
    primary: primary ?? this.primary,
    accent: accent ?? this.accent,
    textSecondary: textSecondary ?? this.textSecondary,
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
      bgGlow: Color.lerp(bgGlow, other.bgGlow, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceVariant: Color.lerp(surfaceVariant, other.surfaceVariant, t)!,
      surfaceHover: Color.lerp(surfaceHover, other.surfaceHover, t)!,
      primary: Color.lerp(primary, other.primary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
    );
  }
}
