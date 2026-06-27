// ============================================================
// lib/main.dart
// T.I.M. (This Is Me) — application entry point.
//
// Boot order:
//   1. Initialise logger.
//   2. Initialise Supabase (auth + encrypted blob sync).
//   3. Hand off to a Riverpod-wrapped [TimApp].
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'app.dart';
import 'core/config/app_config.dart';
import 'core/utils/logger.dart';

Future<void> main() async {
  Logger.init();
  final log = Logger('main');
  log.info('T.I.M. booting (Master Blueprint v0.2)...');

  // Required before any async init in main.
  WidgetsFlutterBinding.ensureInitialized();

  // Load environment variables.
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    // Fall back to --dart-define compiler options if .env isn't found.
  }

  // ---- Supabase init ------------------------------------------------
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabaseAnonKey,
    debug: AppConfig.debug,
  );
  log.info('Supabase initialised: ${AppConfig.supabaseUrl}');

  // ---- Run app ------------------------------------------------------
  runApp(
    // ProviderScope bootstraps Riverpod for the entire widget tree.
    const ProviderScope(child: TimApp()),
  );
}
