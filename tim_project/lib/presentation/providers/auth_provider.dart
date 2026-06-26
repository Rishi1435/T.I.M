// ============================================================
// lib/presentation/providers/auth_provider.dart
// Riverpod state for Supabase multi-tenant auth.
// ============================================================

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../../data/services/supabase_service.dart';

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
  AuthNotifier() : super(const AuthInitial()) {
    _init();
  }

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
    } on AuthException catch (e) {
      state = AuthError(e.message);
    } catch (e) {
      state = AuthError(e.toString());
    }
  }

  Future<void> signUp(String email, String password) async {
    state = const AuthLoading();
    try {
      await SupabaseService.client.auth
          .signUp(email: email, password: password);
      // Onboarding flag stays false until Genesis completes.
    } on AuthException catch (e) {
      state = AuthError(e.message);
    } catch (e) {
      state = AuthError(e.toString());
    }
  }

  Future<void> signOut() async {
    await SupabaseService.client.auth.signOut();
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

final authProvider =
    StateNotifierProvider<AuthNotifier, AuthState>((ref) => AuthNotifier());

/// Has the current user completed Genesis onboarding?
/// Backed by SharedPreferences so it survives app restarts.
final onboardingCompletedProvider = StateProvider<bool>((ref) {
  // The real implementation reads from SharedPreferences in main.dart
  // and seeds this provider. Default false for first-time users.
  return false;
});
