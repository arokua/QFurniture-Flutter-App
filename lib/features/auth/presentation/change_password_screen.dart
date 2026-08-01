import 'package:flutter/material.dart';

import '../../../services/auth_service.dart';
import '../data/password_reset_api.dart';
import '../domain/password_policy.dart';
import 'widgets/new_password_fields.dart';
import 'widgets/password_field.dart';

/// Native change-password for a signed-in user.
///
/// Replaces the "Reset password" tile that opened the storefront in the system
/// browser. Nothing here leaves the app.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  static Future<void> push(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ChangePasswordScreen()),
      );

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _current = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // PasswordField has no onChanged, and _canSubmit depends on this field.
    _current.addListener(_onCurrentChanged);
  }

  void _onCurrentChanged() => setState(() {});

  @override
  void dispose() {
    _current.removeListener(_onCurrentChanged);
    _current.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      !_submitting &&
      _current.text.isNotEmpty &&
      PasswordPolicy.isSubmittable(_password.text, _confirm.text);

  Future<void> _submit() async {
    if (!_canSubmit) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
      _error = null;
    });

    final session = AuthService.instance.currentSession;
    final token = session?.token;
    if (token == null || token.isEmpty) {
      setState(() {
        _submitting = false;
        _error = 'Please sign in again to change your password.';
      });
      return;
    }

    final result = await PasswordResetApi.instance.changePassword(
      jwt: token,
      currentPassword: _current.text,
      newPassword: _password.text,
    );

    if (!mounted) return;

    if (!result.ok) {
      setState(() {
        _submitting = false;
        _error = result.message;
      });
      return;
    }

    // The stored credentials used for silent re-login are now stale; letting
    // them stand would make the next background re-auth fail with the old
    // password and sign the user out.
    await AuthService.instance.onPasswordChanged(_password.text);

    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Password updated.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Change password')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Choose a new password for ${_maskedEmail()}.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                // Possession of the current password is what stops a borrowed
                // unlocked phone from becoming an account takeover.
                PasswordField(
                  controller: _current,
                  labelText: 'Current password',
                  autofillHints: const [AutofillHints.password],
                  textInputAction: TextInputAction.next,
                  enabled: !_submitting,
                ),
                const SizedBox(height: 20),
                NewPasswordFields(
                  passwordController: _password,
                  confirmController: _confirm,
                  enabled: !_submitting,
                  onChanged: () => setState(() {}),
                  onSubmitted: _submit,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  _ErrorBanner(message: _error!),
                ],
                const SizedBox(height: 28),
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: _canSubmit ? _submit : null,
                    child: _submitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Update password'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _maskedEmail() {
    final email = AuthService.instance.currentSession?.email ?? '';
    if (!email.contains('@')) return 'your account';
    final parts = email.split('@');
    final name = parts.first;
    final masked = name.length <= 2
        ? '${name.characters.first}*'
        : '${name.substring(0, 2)}${'*' * (name.length - 2)}';
    return '$masked@${parts.last}';
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
