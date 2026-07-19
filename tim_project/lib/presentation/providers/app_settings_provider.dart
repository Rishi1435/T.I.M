// ============================================================
// lib/presentation/providers/app_settings_provider.dart
// v0.3.4 — persisted user preferences.
//
// From the narrated recording: "no button was being tumbled, I was
// unable to switch on or off anything." Three of the four settings
// toggles were hardcoded `value: true, onChanged: (){}`. They are
// now backed by SharedPreferences and survive restarts.
// ============================================================

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  const AppSettings({
    this.hardwareProfiling = true,
    this.voiceLock = true,
    this.cadenceCoaching = true,
    this.openFreshSessionOnLaunch = true,
    this.loaded = false,
  });

  final bool hardwareProfiling;
  final bool voiceLock;
  final bool cadenceCoaching;
  final bool openFreshSessionOnLaunch;
  final bool loaded;

  AppSettings copyWith({
    bool? hardwareProfiling,
    bool? voiceLock,
    bool? cadenceCoaching,
    bool? openFreshSessionOnLaunch,
    bool? loaded,
  }) =>
      AppSettings(
        hardwareProfiling: hardwareProfiling ?? this.hardwareProfiling,
        voiceLock: voiceLock ?? this.voiceLock,
        cadenceCoaching: cadenceCoaching ?? this.cadenceCoaching,
        openFreshSessionOnLaunch:
            openFreshSessionOnLaunch ?? this.openFreshSessionOnLaunch,
        loaded: loaded ?? this.loaded,
      );
}

class AppSettingsNotifier extends StateNotifier<AppSettings> {
  AppSettingsNotifier() : super(const AppSettings()) {
    _load();
  }

  static const _kHw = 'settings.hardwareProfiling';
  static const _kVoiceLock = 'settings.voiceLock';
  static const _kCadence = 'settings.cadenceCoaching';
  static const _kFresh = 'settings.openFreshSessionOnLaunch';

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    state = AppSettings(
      hardwareProfiling: p.getBool(_kHw) ?? true,
      voiceLock: p.getBool(_kVoiceLock) ?? true,
      cadenceCoaching: p.getBool(_kCadence) ?? true,
      openFreshSessionOnLaunch: p.getBool(_kFresh) ?? true,
      loaded: true,
    );
  }

  Future<void> _save(String key, bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(key, value);
  }

  void setHardwareProfiling(bool v) {
    state = state.copyWith(hardwareProfiling: v);
    _save(_kHw, v);
  }

  void setVoiceLock(bool v) {
    state = state.copyWith(voiceLock: v);
    _save(_kVoiceLock, v);
  }

  void setCadenceCoaching(bool v) {
    state = state.copyWith(cadenceCoaching: v);
    _save(_kCadence, v);
  }

  void setOpenFreshSessionOnLaunch(bool v) {
    state = state.copyWith(openFreshSessionOnLaunch: v);
    _save(_kFresh, v);
  }
}

final appSettingsProvider =
    StateNotifierProvider<AppSettingsNotifier, AppSettings>(
        (ref) => AppSettingsNotifier());
