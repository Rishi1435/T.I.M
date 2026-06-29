// ============================================================
// lib/presentation/screens/login_screen.dart
// Redesigned premium login screen.
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../providers/auth_provider.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _isSignUp = false;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    if (_isSignUp) {
      await ref.read(authProvider.notifier).signUp(
            _email.text.trim(),
            _password.text,
          );
    } else {
      await ref.read(authProvider.notifier).signIn(
            _email.text.trim(),
            _password.text,
          );
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final errMsg = auth is AuthError ? auth.message : null;
    final theme = Theme.of(context);
    final palette = theme.extension<TimPalette>()!;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0.0, -0.4),
            radius: 1.2,
            colors: [
              palette.bgGlow,
              palette.bg,
            ],
            stops: const [0.0, 0.8],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxWidth: 400),
              margin: const EdgeInsets.all(24),
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Brand Logo / Icon
                    Center(
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: palette.surfaceVariant,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          'T',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: palette.primary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Titles
                    Center(
                      child: Text(
                        'T.I.M. Companion',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Center(
                      child: Text(
                        _isSignUp ? 'Create your secure local profile' : 'This Is Me — Sign In',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: palette.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),

                    // Email Input
                    Text(
                      'Email Address',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: palette.muted,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(
                        hintText: 'name@example.com',
                        hintStyle: TextStyle(color: palette.muted),
                        prefixIcon: Icon(Icons.email_outlined, color: palette.textSecondary, size: 20),
                        fillColor: palette.surfaceVariant,
                        filled: true,
                      ),
                      validator: (v) => (v == null || !v.contains('@')) ? 'Invalid email' : null,
                    ),
                    const SizedBox(height: 20),

                    // Password Input
                    Text(
                      'Password',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: palette.muted,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _password,
                      obscureText: true,
                      decoration: InputDecoration(
                        hintText: 'Enter your password',
                        hintStyle: TextStyle(color: palette.muted),
                        prefixIcon: Icon(Icons.lock_outline, color: palette.textSecondary, size: 20),
                        fillColor: palette.surfaceVariant,
                        filled: true,
                      ),
                      validator: (v) => (v == null || v.length < 6) ? 'Min 6 characters' : null,
                    ),

                    if (errMsg != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: palette.danger.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: palette.danger.withValues(alpha: 0.2)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline, color: palette.danger, size: 16),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                errMsg,
                                style: TextStyle(color: palette.danger, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 32),

                    // Submit Button
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: _busy ? null : _submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: palette.primary,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: _busy
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.black),
                                ),
                              )
                            : Text(
                                _isSignUp ? 'Create Profile' : 'Sign In',
                                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                              ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Toggle Link
                    Center(
                      child: TextButton(
                        onPressed: _busy ? null : () => setState(() => _isSignUp = !_isSignUp),
                        child: Text(
                          _isSignUp ? 'Already have an account? Sign in' : 'New user? Create a profile',
                          style: TextStyle(
                            color: palette.primary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
