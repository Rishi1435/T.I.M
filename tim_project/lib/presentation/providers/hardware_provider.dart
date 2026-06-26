// ============================================================
// lib/presentation/providers/hardware_provider.dart
// Reads the [HardwareProfile] once at startup and exposes it to the
// UI so the model-head selector + battery warnings can react.
// ============================================================

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../platform/channels/hardware_scanner.dart';

final hardwareProvider = FutureProvider<HardwareProfile>((ref) async {
  return HardwareScanner.scan();
});
