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
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _isSignUp = false;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    if (_isSignUp) {
      await ref.read(authProvider.notifier).signUp(
            _email.text.trim(),
            _password.text,
            name: _name.text.trim(),
          );
    } else {
      await ref.read(authProvider.notifier).signIn(
            _email.text.trim(),
            _password.text,
          );
    }
    if (mounted) setState(() => _busy = false);
  }

  void _switchMode() {
    setState(() {
      _isSignUp = !_isSignUp;
      // Different journey, clean slate: only the email survives the
      // switch so sign-in and registration feel like separate doors.
      _password.clear();
      _confirm.clear();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
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

                    // Titles — sign-in and registration are distinct
                    // journeys, not the same card with swapped labels.
                    Center(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: Column(
                          key: ValueKey(_isSignUp),
                          children: [
                            Text(
                              _isSignUp ? 'Meet T.I.M.' : 'Welcome back',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _isSignUp
                                  ? 'Your offline career mentor. One profile, '
                                      'one password — everything stays '
                                      'encrypted on this PC.'
                                  : 'This Is Me — Sign In',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: palette.textSecondary,
                                fontSize: 14,
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),

                    // Your name (registration only)
                    AnimatedSize(
                      duration: const Duration(milliseconds: 250),
                      alignment: Alignment.topCenter,
                      child: !_isSignUp
                          ? const SizedBox.shrink()
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Your Name',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: palette.muted,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                TextFormField(
                                  controller: _name,
                                  textCapitalization:
                                      TextCapitalization.words,
                                  decoration: InputDecoration(
                                    hintText: 'What should T.I.M. call you?',
                                    hintStyle:
                                        TextStyle(color: palette.muted),
                                    prefixIcon: Icon(Icons.person_outline,
                                        color: palette.textSecondary,
                                        size: 20),
                                    fillColor: palette.surfaceVariant,
                                    filled: true,
                                  ),
                                  validator: (v) => _isSignUp &&
                                          (v == null || v.trim().isEmpty)
                                      ? 'Tell T.I.M. your name'
                                      : null,
                                ),
                                const SizedBox(height: 20),
                              ],
                            ),
                    ),

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
                    AnimatedSize(
                      duration: const Duration(milliseconds: 250),
                      alignment: Alignment.topCenter,
                      child: !_isSignUp
                          ? const SizedBox.shrink()
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 8),
                                Text(
                                  'This password also encrypts your local '
                                  'memory vault — losing it means losing '
                                  'access to your data.',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: palette.muted,
                                      height: 1.4),
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  'Confirm Password',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: palette.muted,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                TextFormField(
                                  controller: _confirm,
                                  obscureText: true,
                                  decoration: InputDecoration(
                                    hintText: 'Re-enter your password',
                                    hintStyle:
                                        TextStyle(color: palette.muted),
                                    prefixIcon: Icon(Icons.lock_outline,
                                        color: palette.textSecondary,
                                        size: 20),
                                    fillColor: palette.surfaceVariant,
                                    filled: true,
                                  ),
                                  validator: (v) => _isSignUp &&
                                          v != _password.text
                                      ? 'Passwords do not match'
                                      : null,
                                ),
                              ],
                            ),
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
                                _isSignUp ? 'Create My Profile' : 'Sign In',
                                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                              ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Toggle Link
                    Center(
                      child: TextButton(
                        onPressed: _busy ? null : _switchMode,
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
