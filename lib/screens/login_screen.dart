import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/brand.dart';
import '../controllers/auth_controller.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _shake.dispose();
    super.dispose();
  }

  String _friendlyLoginError(Object e) {
    final s = e.toString().replaceFirst('Exception: ', '');
    // Specific causes first — the controller wraps them in a generic prefix.
    if (s.contains('disabled')) {
      return 'This account has been disabled. Ask an admin.';
    }
    if (s.contains('profile not found')) {
      return 'Your account is not set up yet. Ask an admin.';
    }
    if (s.contains('network')) {
      return 'No connection. Check the Wi-Fi and try again.';
    }
    if (s.contains('Wrong password') ||
        s.contains('No user found') ||
        s.contains('invalid-credential') ||
        s.contains('An error occurred during sign in')) {
      return "That email and password don't match. Try again or reset your password.";
    }
    return s;
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await ref
          .read(authControllerProvider.notifier)
          .signInWithEmailAndPassword(
            _emailController.text.trim(),
            _passwordController.text,
          );
      // Navigation is handled by the router.
    } catch (e) {
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() {
        _errorMessage = _friendlyLoginError(e);
        _isLoading = false;
      });
      if (!MediaQuery.of(context).disableAnimations) {
        _shake.forward(from: 0);
      }
    }
  }

  InputDecoration _fieldDecoration({required bool error, Widget? suffix}) {
    OutlineInputBorder border(Color c, double w) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c, width: w),
        );
    return InputDecoration(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      suffixIcon: suffix,
      enabledBorder: border(error ? AppColors.red : AppColors.field, error ? 2 : 1),
      focusedBorder: border(error ? AppColors.red : AppColors.navy, 2),
      errorBorder: border(AppColors.red, 2),
      focusedErrorBorder: border(AppColors.red, 2),
    );
  }

  Widget _compactBrandPanel() {
    return Container(
      // Same forest green as the launch splash.
      color: AppColors.forest,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(
            right: -120,
            top: -90,
            child: Opacity(
              opacity: 0.14,
              // Draws itself once, like the launch splash.
              child: const DrawnBrandMark(
                size: 340,
                arrows: Colors.white,
                strips: Colors.white,
                duration: Duration(milliseconds: 1600),
              ),
            ),
          ),
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              child: Row(
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: AppColors.cream,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    alignment: Alignment.center,
                    child: const BrandMark(size: 46),
                  ),
                  const SizedBox(width: 14),
                  const Text(
                    'Camacho Daily Log',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _brandPanel() {
    return Container(
      // Same forest green as the launch splash.
      color: AppColors.forest,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(
            right: -200,
            bottom: -170,
            child: Opacity(
              opacity: 0.14,
              // Draws itself once, like the launch splash.
              child: const DrawnBrandMark(
                size: 560,
                arrows: Colors.white,
                strips: Colors.white,
                duration: Duration(milliseconds: 1600),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(56),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        color: AppColors.cream,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      alignment: Alignment.center,
                      child: const BrandMark(size: 46),
                    ),
                    const SizedBox(width: 14),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text(
                          'CAMACHO',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.5,
                          ),
                        ),
                        Text(
                          'RECYCLING',
                          style: TextStyle(
                            color: AppColors.sageLight,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 3,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const Spacer(),
                const Text(
                  'Daily Log',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 44,
                    height: 1.15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                const SizedBox(
                  width: 380,
                  child: Text(
                    'Log every customer, capture their signature, and hand them a receipt — on paper, by text or by QR.',
                    style: TextStyle(
                      color: Color(0xFFDCE8D2),
                      fontSize: 17,
                      height: 1.6,
                    ),
                  ),
                ),
                const Spacer(),
                const Text(
                  'CA CRV certified recycling',
                  style: TextStyle(color: Color(0xB3FAF8F1), fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _form() {
    final hasError = _errorMessage != null;
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Sign in',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            'Use the staff account your admin created.',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: AppColors.slate, fontSize: 15),
          ),
          const SizedBox(height: 28),
          const Text('Email', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          TextFormField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            style: const TextStyle(fontSize: 16),
            decoration: _fieldDecoration(error: false),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Enter your email';
              }
              if (!value.contains('@')) return 'Enter a valid email';
              return null;
            },
          ),
          const SizedBox(height: 20),
          const Text('Password', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          AnimatedBuilder(
            animation: _shake,
            builder: (context, child) {
              final t = _shake.value;
              final dx = math.sin(t * math.pi * 6) * 8 * (1 - t);
              return Transform.translate(offset: Offset(dx, 0), child: child);
            },
            child: TextFormField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _isLoading ? null : _handleLogin(),
              style: const TextStyle(fontSize: 16),
              onChanged: (_) {
                if (_errorMessage != null) setState(() => _errorMessage = null);
              },
              decoration: _fieldDecoration(
                error: hasError,
                suffix: IconButton(
                  tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    color: AppColors.slate,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) return 'Enter your password';
                return null;
              },
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            child: hasError
                ? Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.error_outline,
                            size: 16, color: AppColors.redText),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.redText,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 56,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.forest,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: _isLoading ? null : _handleLogin,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: _isLoading
                    ? const SizedBox(
                        key: ValueKey('spin'),
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Sign in',
                        key: ValueKey('label'),
                        style: TextStyle(fontSize: 16)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              onPressed: () => context.go('/forgot-password'),
              child: const Text(
                'Forgot password?',
                style: TextStyle(color: AppColors.blue, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 900;
    final formPane = Container(
      color: AppColors.mist,
      alignment: Alignment.center,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Entrance(child: _form()),
        ),
      ),
    );

    return Scaffold(
      backgroundColor: AppColors.mist,
      body: wide
          ? Row(
              children: [
                Expanded(child: _brandPanel()),
                Expanded(child: formPane),
              ],
            )
          : Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  height: 180,
                  child: _compactBrandPanel(),
                ),
                Expanded(child: formPane),
              ],
            ),
    );
  }
}
