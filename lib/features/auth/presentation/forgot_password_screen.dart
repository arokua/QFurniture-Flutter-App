import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/auth_service.dart';
import '../data/password_reset_api.dart';
import '../domain/password_policy.dart';
import 'widgets/new_password_fields.dart';

enum _Step { email, code, password }

/// Fully native forgot-password: email → emailed code → new password.
///
/// Deliberately one screen with an internal pager rather than three routes.
/// Route transitions would re-run each step's build and animate a full page
/// push between what the user experiences as parts of a single task; this way
/// each step slides in immediately and the earlier state stays alive, so
/// going back is free.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, this.initialEmail});

  final String? initialEmail;

  static Future<bool?> push(BuildContext context, {String? initialEmail}) =>
      Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => ForgotPasswordScreen(initialEmail: initialEmail),
        ),
      );

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  _Step _step = _Step.email;
  bool _busy = false;
  String? _error;
  String? _notice;

  /// Seconds left before another code can be requested. Keeps the user from
  /// hammering an endpoint that will rate-limit them anyway.
  int _resendCooldown = 0;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    _emailController.text = widget.initialEmail?.trim() ?? '';
    _codeController.addListener(_onCodeChanged);
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _codeController.removeListener(_onCodeChanged);
    _emailController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _onCodeChanged() => setState(() {});

  void _startCooldown([int seconds = 45]) {
    _cooldownTimer?.cancel();
    setState(() => _resendCooldown = seconds);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _resendCooldown -= 1);
      if (_resendCooldown <= 0) t.cancel();
    });
  }

  bool get _emailLooksValid {
    final v = _emailController.text.trim();
    return v.length > 3 && v.contains('@') && !v.endsWith('@');
  }

  // ------------------------------------------------------------------ actions

  Future<void> _sendCode({bool resend = false}) async {
    if (_busy || !_emailLooksValid) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });

    final result = await PasswordResetApi.instance
        .requestCode(email: _emailController.text);

    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) {
        // Advance regardless of whether the address exists — the server never
        // tells us, by design, and neither does this screen.
        _step = _Step.code;
        _notice = resend ? 'We\'ve sent another code.' : result.message;
      } else {
        _error = result.message;
      }
    });
    if (result.ok) _startCooldown();
  }

  Future<void> _verifyAndReset() async {
    if (_busy) return;
    if (!PasswordPolicy.isSubmittable(
      _passwordController.text,
      _confirmController.text,
    )) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });

    final result = await PasswordResetApi.instance.confirm(
      email: _emailController.text,
      code: _codeController.text,
      newPassword: _passwordController.text,
    );

    if (!mounted) return;

    if (!result.ok) {
      setState(() {
        _busy = false;
        _error = result.message;
        // A bad code is fixable in place; send them back rather than leaving
        // them staring at a password form they already filled in correctly.
        if (result.message?.contains('code') ?? false) _step = _Step.code;
      });
      return;
    }

    final token = result.token;
    if (token != null && token.isNotEmpty) {
      await AuthService.instance.adoptResetSession(
        email: _emailController.text.trim(),
        token: token,
        password: _passwordController.text,
      );
    }

    if (!mounted) return;
    Navigator.of(context).pop(true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          token != null && token.isNotEmpty
              ? 'Password updated — you\'re signed in.'
              : 'Password updated. Please sign in.',
        ),
      ),
    );
  }

  void _back() {
    setState(() {
      _error = null;
      _notice = null;
      _step = switch (_step) {
        _Step.password => _Step.code,
        _Step.code => _Step.email,
        _Step.email => _Step.email,
      };
    });
  }

  // -------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _step == _Step.email,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Reset password'),
          leading: BackButton(
            onPressed: () {
              if (_step == _Step.email) {
                Navigator.of(context).pop();
              } else {
                _back();
              }
            },
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              _StepIndicator(step: _step),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween(
                          begin: const Offset(0.04, 0),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: KeyedSubtree(
                      key: ValueKey(_step),
                      child: switch (_step) {
                        _Step.email => _buildEmailStep(),
                        _Step.code => _buildCodeStep(),
                        _Step.password => _buildPasswordStep(),
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmailStep() {
    return Column(
      key: const ValueKey('email'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'What email do you use for your Qtoys account?',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'We\'ll send you a 6-digit code to confirm it\'s you.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _emailController,
          enabled: !_busy,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.email],
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _sendCode(),
          decoration: InputDecoration(
            labelText: 'Email',
            prefixIcon: const Icon(Icons.mail_outline),
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        _messages(),
        const SizedBox(height: 24),
        _primaryButton(
          label: 'Send code',
          onPressed: _emailLooksValid ? _sendCode : null,
        ),
      ],
    );
  }

  Widget _buildCodeStep() {
    final code = _codeController.text.trim();
    return Column(
      key: const ValueKey('code'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Enter your code',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'We sent a 6-digit code to ${_emailController.text.trim()}. '
          'It expires in 15 minutes.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _codeController,
          enabled: !_busy,
          autofocus: true,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          maxLength: 6,
          style: const TextStyle(fontSize: 24, letterSpacing: 10),
          textAlign: TextAlign.center,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          onSubmitted: (_) {
            if (code.length == 6) setState(() => _step = _Step.password);
          },
          decoration: InputDecoration(
            counterText: '',
            hintText: '000000',
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        _messages(),
        const SizedBox(height: 16),
        _primaryButton(
          label: 'Continue',
          // The code is only checked when the new password is submitted, so
          // there is nothing to wait for here — moving on is instant.
          onPressed:
              code.length == 6 ? () => setState(() => _step = _Step.password) : null,
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy || _resendCooldown > 0
              ? null
              : () => _sendCode(resend: true),
          child: Text(
            _resendCooldown > 0
                ? 'Resend code in ${_resendCooldown}s'
                : 'Send a new code',
          ),
        ),
      ],
    );
  }

  Widget _buildPasswordStep() {
    return Column(
      key: const ValueKey('password'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Choose a new password',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 20),
        NewPasswordFields(
          passwordController: _passwordController,
          confirmController: _confirmController,
          enabled: !_busy,
          onChanged: () => setState(() {}),
          onSubmitted: _verifyAndReset,
        ),
        _messages(),
        const SizedBox(height: 24),
        _primaryButton(
          label: 'Reset password',
          onPressed: PasswordPolicy.isSubmittable(
            _passwordController.text,
            _confirmController.text,
          )
              ? _verifyAndReset
              : null,
        ),
      ],
    );
  }

  Widget _messages() {
    final error = _error;
    final notice = _notice;
    if (error == null && notice == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final isError = error != null;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isError ? scheme.errorContainer : scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.mark_email_read_outlined,
              size: 18,
              color: isError
                  ? scheme.onErrorContainer
                  : scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                error ?? notice!,
                style: TextStyle(
                  height: 1.35,
                  color: isError
                      ? scheme.onErrorContainer
                      : scheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _primaryButton({required String label, VoidCallback? onPressed}) {
    return SizedBox(
      height: 48,
      child: FilledButton(
        onPressed: _busy ? null : onPressed,
        child: _busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(label),
      ),
    );
  }
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.step});

  final _Step step;

  @override
  Widget build(BuildContext context) {
    final index = _Step.values.indexOf(step);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Row(
        children: [
          for (var i = 0; i < _Step.values.length; i++) ...[
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                height: 4,
                decoration: BoxDecoration(
                  color: i <= index
                      ? scheme.primary
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            if (i < _Step.values.length - 1) const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}
