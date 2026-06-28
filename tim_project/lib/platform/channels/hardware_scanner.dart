// ============================================================
// lib/platform/channels/hardware_scanner.dart
// Native platform channel client. Calls into a MethodChannel handler
// registered on the Windows runner (C++) to read system RAM, dedicated
// VRAM (via DXGI), and battery state at startup.
//
// Returned values drive the .gguf model recommendation:
//   - Plugged in + 16 GB+ RAM + 6 GB+ VRAM  → Llama 3 (8B) / Qwen3 (14B)
//   - Battery power or < 8 GB RAM           → Qwen2.5 (3B) / Phi-3-Mini
//
// Native side is registered as `tim.hardware/scanner` in
// windows/runner/flutter_window.cc (see windows/runner/README.md).
// ============================================================

import 'package:flutter/services.dart';

class HardwareProfile {
  const HardwareProfile({
    required this.totalRamGb,
    required this.availableRamGb,
    required this.dedicatedVramGb,
    required this.batteryPercent,
    required this.isCharging,
    required this.gpuName,
  });

  final double totalRamGb;
  final double availableRamGb;
  final double dedicatedVramGb;
  final int batteryPercent;
  final bool isCharging;
  final String gpuName;

  /// Human-readable representation of battery status, handling the Win32 '255' byte cap
  /// for desktops / plugged-in laptops without a reporting battery driver.
  String get batteryStatusString => batteryPercent == 255 ? 'Desktop / Plugged In' : '$batteryPercent%';

  /// True iff the host has enough RAM + (optional) VRAM for [model].
  bool canRun(AppConfigGgufModelLite model) {
    if (totalRamGb < model.minRamGb) return false;
    if (model.minVramGb > 0 && dedicatedVramGb < model.minVramGb) return false;
    if (!isCharging && !model.batteryOk) return false;
    return true;
  }

  /// Convenience predicates used by the recommendation engine.
  bool get isHighSpec =>
      isCharging && totalRamGb >= 16 && dedicatedVramGb >= 6;
  bool get isLowSpec =>
      !isCharging || totalRamGb < 8;

  @override
  String toString() =>
      'HW(ram=${totalRamGb.toStringAsFixed(1)}GB '
      'vram=${dedicatedVramGb.toStringAsFixed(1)}GB '
      'battery=$batteryStatusString charging=$isCharging '
      'gpu=$gpuName)';
}

/// Lightweight mirror of [GgufModel] used by [HardwareProfile.canRun].
/// Defined here to avoid an import cycle with app_config.dart.
class AppConfigGgufModelLite {
  const AppConfigGgufModelLite({
    required this.id,
    required this.minRamGb,
    required this.minVramGb,
    required this.batteryOk,
  });
  final String id;
  final double minRamGb;
  final double minVramGb;
  final bool batteryOk;
}

class HardwareScanner {
  static const MethodChannel _channel =
      MethodChannel('tim.hardware/scanner');

  /// Probe the native host for RAM + VRAM + battery. Falls back to safe
  /// defaults if the channel is not yet wired (web/test/CI).
  static Future<HardwareProfile> scan() async {
    try {
      final result = await _channel.invokeMethod<Map>('scan');
      return HardwareProfile(
        totalRamGb: (result?['totalRamGb'] as num?)?.toDouble() ?? 16.0,
        availableRamGb:
            (result?['availableRamGb'] as num?)?.toDouble() ?? 8.0,
        dedicatedVramGb:
            (result?['dedicatedVramGb'] as num?)?.toDouble() ?? 0.0,
        batteryPercent: (result?['batteryPercent'] as num?)?.toInt() ?? 100,
        isCharging: (result?['isCharging'] as bool?) ?? true,
        gpuName: (result?['gpuName'] as String?) ?? 'Unknown GPU',
      );
    } on PlatformException catch (_) {
      return _fallback();
    } on MissingPluginException catch (_) {
      return _fallback();
    }
  }

  static HardwareProfile _fallback() => const HardwareProfile(
        totalRamGb: 16.0,
        availableRamGb: 8.0,
        dedicatedVramGb: 6.0,
        batteryPercent: 100,
        isCharging: true,
        gpuName: 'Fallback GPU',
      );
}
