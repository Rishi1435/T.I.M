// ============================================================
// lib/presentation/providers/auth_provider.dart
// Riverpod state for Supabase multi-tenant auth.
// ============================================================

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import 'package:shared_preferences/shared_preferences.dart';

import '../../data/services/supabase_service.dart';
import 'vault_provider.dart';

@immutable
sealed class AuthState {
  const AuthState();
}

class AuthInitial extends AuthState {
  const AuthInitial();
}

class AuthLoading extends AuthState {
  const AuthLoading();
}

class Authenticated extends AuthState {
  const Authenticated(this.user);
  final User user;
}

class Unauthenticated extends AuthState {
  const Unauthenticated();
}

class AuthError extends AuthState {
  const AuthError(this.message);
  final String message;
}

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier(this.ref) : super(const AuthInitial()) {
    _init();
  }

  final Ref ref;
  late final StreamSubscription<dynamic> _sub;

  Future<void> _init() async {
    state = const AuthLoading();
    final current = SupabaseService.currentUser;
    state = current != null
        ? Authenticated(current)
        : const Unauthenticated();

    _sub = SupabaseService.authChanges.listen((event) {
      final user = event.session?.user;
      state = user != null
          ? Authenticated(user)
          : const Unauthenticated();
    });
  }

  Future<void> signIn(String email, String password) async {
    state = const AuthLoading();
    try {
      await SupabaseService.client.auth
          .signInWithPassword(email: email, password: password);
      // Automatically unlock the local vault with the login password
      await ref.read(vaultProvider.notifier).unlock(password);
    } on AuthException catch (e) {
      state = AuthError(e.message);
    } catch (e) {
      state = AuthError(e.toString());
    }
  }

  Future<void> signUp(String email, String password, {String? name}) async {
    state = const AuthLoading();
    try {
      await SupabaseService.client.auth.signUp(
        email: email,
        password: password,
        data: name != null && name.trim().isNotEmpty
            ? {'display_name': name.trim()}
            : null,
      );
      // Automatically unlock the local vault with the signup password
      await ref.read(vaultProvider.notifier).unlock(password);
    } on AuthException catch (e) {
      state = AuthError(e.message);
    } catch (e) {
      state = AuthError(e.toString());
    }
  }

  Future<void> signOut() async {
    ref.read(vaultProvider.notifier).lock();
    await SupabaseService.client.auth.signOut();
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

final authProvider =
    StateNotifierProvider<AuthNotifier, AuthState>((ref) => AuthNotifier(ref));

class OnboardingCompletedNotifier extends StateNotifier<bool> {
  OnboardingCompletedNotifier() : super(false) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = SupabaseService.currentUserId;
      if (userId.isNotEmpty) {
        state = prefs.getBool('onboarding_completed_$userId') ?? false;
      }
    } catch (_) {}
  }

  Future<void> setCompleted(bool completed) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = SupabaseService.currentUserId;
      if (userId.isNotEmpty) {
        await prefs.setBool('onboarding_completed_$userId', completed);
      }
    } catch (_) {}
    state = completed;
  }
}

final onboardingCompletedProvider =
    StateNotifierProvider<OnboardingCompletedNotifier, bool>((ref) {
  final authState = ref.watch(authProvider);
  final notifier = OnboardingCompletedNotifier();
  if (authState is Authenticated) {
    notifier._load();
  }
  return notifier;
});
