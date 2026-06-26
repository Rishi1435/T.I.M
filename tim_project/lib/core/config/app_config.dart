// ============================================================
// lib/core/config/app_config.dart
// Central compile-time configuration. Values are injected via
// --dart-define so secrets never live in source.
// ============================================================

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConfig {
  const AppConfig._();

  static bool get debug =>
      const bool.fromEnvironment('DEBUG', defaultValue: false) ||
      (dotenv.isInitialized && dotenv.env['DEBUG']?.toLowerCase() == 'true');

  static String get supabaseUrl =>
      const String.fromEnvironment('SUPABASE_URL').isNotEmpty
          ? const String.fromEnvironment('SUPABASE_URL')
          : (dotenv.isInitialized ? dotenv.env['SUPABASE_URL'] : null) ?? '';

  static String get supabaseAnonKey =>
      const String.fromEnvironment('SUPABASE_ANON_KEY').isNotEmpty
          ? const String.fromEnvironment('SUPABASE_ANON_KEY')
          : (dotenv.isInitialized ? dotenv.env['SUPABASE_ANON_KEY'] : null) ?? '';

  /// WebSocket URL of the local Python audio / vision / scraper worker.
  static String get wsUrl =>
      const String.fromEnvironment('WS_URL').isNotEmpty
          ? const String.fromEnvironment('WS_URL')
          : (dotenv.isInitialized ? dotenv.env['WS_URL'] : null) ?? 'ws://127.0.0.1:8765';

  /// Voice-mode tuning. Mirrored from `backend/audio_server.py` so the
  /// UI can render the same silence threshold the server enforces.
  static const int vadSilenceThresholdMs = 800;

  /// Default .gguf model registry. The hardware profiler picks one of
  /// these based on RAM/VRAM/battery. URLs are HuggingFace direct.
  static const Map<String, GgufModel> modelRegistry = {
    'llama3-8b': GgufModel(
      id: 'llama3-8b',
      label: 'Llama 3 (8B)',
      sizeGb: 4.9,
      minRamGb: 16,
      minVramGb: 6,
      batteryOk: false,
      url: 'https://huggingface.co/QuantFactory/Meta-Llama-3-8B-Instruct-GGUF'
           '/resolve/main/Meta-Llama-3-8B-Instruct.Q4_K_M.gguf',
    ),
    'qwen3-14b': GgufModel(
      id: 'qwen3-14b',
      label: 'Qwen3 (14B)',
      sizeGb: 8.2,
      minRamGb: 24,
      minVramGb: 8,
      batteryOk: false,
      url: 'https://huggingface.co/Qwen/Qwen3-14B-Instruct-GGUF'
           '/resolve/main/qwen3-14b-instruct-q4_k_m.gguf',
    ),
    'qwen25-3b': GgufModel(
      id: 'qwen25-3b',
      label: 'Qwen2.5 (3B)',
      sizeGb: 1.9,
      minRamGb: 8,
      minVramGb: 0,
      batteryOk: true,
      url: 'https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF'
           '/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf',
    ),
    'phi3-mini': GgufModel(
      id: 'phi3-mini',
      label: 'Phi-3-Mini (3.8B)',
      sizeGb: 2.3,
      minRamGb: 8,
      minVramGb: 0,
      batteryOk: true,
      url: 'https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf'
           '/resolve/main/Phi-3-mini-4k-instruct-q4.gguf',
    ),
  };
}

@immutable
class GgufModel {
  const GgufModel({
    required this.id,
    required this.label,
    required this.sizeGb,
    required this.minRamGb,
    required this.minVramGb,
    required this.batteryOk,
    required this.url,
  });
  final String id;
  final String label;
  final double sizeGb;
  final double minRamGb;
  final double minVramGb;
  final bool batteryOk;
  final String url;
}
