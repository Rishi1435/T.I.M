// ============================================================
// lib/app.dart
// Root MaterialApp. Dark-mode default, Gemini-style aesthetic.
// Routes between Login → Genesis Onboarding → Home based on
// combined auth + vault unlock state.
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_theme.dart';
import 'presentation/providers/auth_provider.dart';
import 'presentation/screens/home_screen.dart';
import 'presentation/screens/login_screen.dart';

class TimApp extends ConsumerWidget {
  const TimApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Combined auth + onboarding state drives the root route.
    final authState = ref.watch(authProvider);

    return MaterialApp(
      title: 'T.I.M. — This Is Me',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: AppTheme.dark,
      darkTheme: AppTheme.dark,
      home: switch (authState) {
        Authenticated() => const _PostAuthRouter(),
        _ => const LoginScreen(),
      },
    );
  }
}

class _PostAuthRouter extends ConsumerWidget {
  const _PostAuthRouter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const HomeScreen();
  }
}
