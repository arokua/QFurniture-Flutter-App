import 'package:flutter/material.dart';

import '../../domain/password_policy.dart';
import 'password_field.dart';

/// The new-password + confirm pair, with a live strength meter.
///
/// Every judgement here is computed locally on each keystroke, so the meter,
/// the match indicator and the submit button all react instantly — nothing in
/// this widget waits on the network. Built on [PasswordField] so the caret-
/// preserving show/hide toggle is shared rather than reimplemented.
class NewPasswordFields extends StatefulWidget {
  const NewPasswordFields({
    super.key,
    required this.passwordController,
    required this.confirmController,
    this.enabled = true,
    this.onChanged,
    this.onSubmitted,
    this.passwordLabel = 'New password',
    this.confirmLabel = 'Confirm new password',
    this.autofocus = false,
  });

  final TextEditingController passwordController;
  final TextEditingController confirmController;
  final bool enabled;

  /// Fires on every keystroke so the parent can enable/disable its submit
  /// button without rebuilding this subtree.
  final VoidCallback? onChanged;

  /// Invoked from the confirm field's keyboard action when the pair is valid.
  final VoidCallback? onSubmitted;

  final String passwordLabel;
  final String confirmLabel;
  final bool autofocus;

  @override
  State<NewPasswordFields> createState() => _NewPasswordFieldsState();
}

class _NewPasswordFieldsState extends State<NewPasswordFields> {
  @override
  void initState() {
    super.initState();
    widget.passwordController.addListener(_onChanged);
    widget.confirmController.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.passwordController.removeListener(_onChanged);
    widget.confirmController.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final password = widget.passwordController.text;
    final confirm = widget.confirmController.text;
    final strength = PasswordPolicy.strengthOf(password);
    final matches = confirm.isNotEmpty && confirm == password;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PasswordField(
          controller: widget.passwordController,
          labelText: widget.passwordLabel,
          enabled: widget.enabled,
          autofillHints: const [AutofillHints.newPassword],
          textInputAction: TextInputAction.next,
          validator: PasswordPolicy.validate,
        ),
        if (password.isNotEmpty) ...[
          const SizedBox(height: 10),
          _StrengthMeter(strength: strength),
        ],
        const SizedBox(height: 16),
        PasswordField(
          controller: widget.confirmController,
          labelText: widget.confirmLabel,
          enabled: widget.enabled,
          autofillHints: const [AutofillHints.newPassword],
          textInputAction: TextInputAction.done,
          validator: (v) =>
              PasswordPolicy.validateConfirmation(v, widget.passwordController.text),
          onSubmitted: (_) {
            if (PasswordPolicy.isSubmittable(password, confirm)) {
              widget.onSubmitted?.call();
            }
          },
        ),
        // Only affirm a match; a mismatch is already reported by the field's
        // own validator, and saying it twice reads as nagging.
        if (matches) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.check_circle, size: 16, color: Color(0xFF2E7D32)),
              const SizedBox(width: 6),
              Text(
                'Passwords match',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF2E7D32),
                    ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _StrengthMeter extends StatelessWidget {
  const _StrengthMeter({required this.strength});

  final PasswordStrength strength;

  static const _colours = {
    PasswordStrength.tooShort: Color(0xFFBDBDBD),
    PasswordStrength.weak: Color(0xFFD32F2F),
    PasswordStrength.fair: Color(0xFFF9A825),
    PasswordStrength.strong: Color(0xFF2E7D32),
  };

  @override
  Widget build(BuildContext context) {
    final colour = _colours[strength]!;
    return Semantics(
      label: 'Password strength: ${strength.label}',
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: strength.fill),
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                builder: (context, value, _) => LinearProgressIndicator(
                  value: value,
                  minHeight: 5,
                  backgroundColor: Colors.grey.shade300,
                  valueColor: AlwaysStoppedAnimation<Color>(colour),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            strength.label,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: colour, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
