import 'package:flutter/material.dart';

/// Password input with a show/hide toggle.
///
/// Toggling `obscureText` on a bare [TextField] moves the caret to the end of
/// the text, which loses the user's place mid-edit. This restores the exact
/// selection after the rebuild so revealing the password never disturbs typing.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    this.labelText = 'Password',
    this.textInputAction,
    this.onSubmitted,
    this.autofillHints = const [AutofillHints.password],
    this.enabled = true,
    this.errorText,
    this.validator,
  });

  final TextEditingController controller;
  final String labelText;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final Iterable<String>? autofillHints;
  final bool enabled;

  /// Validation message. Preserved across visibility toggles because the
  /// toggle only flips local state — it never rebuilds the field's value.
  final String? errorText;

  /// Form validator. Rendered through a [TextFormField] so an enclosing [Form]
  /// keeps working; toggling visibility does not clear the validation state.
  final FormFieldValidator<String>? validator;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _obscured = true;
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _toggle() {
    final selection = widget.controller.selection;
    setState(() => _obscured = !_obscured);

    // The field rebuilds with a new obscuring state; put the caret back where
    // the user left it, on the next frame so the rebuild has settled.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final text = widget.controller.text;
      if (selection.start < 0 || selection.end > text.length) return;
      widget.controller.selection = selection;
    });
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      focusNode: _focusNode,
      obscureText: _obscured,
      enabled: widget.enabled,
      autofillHints: widget.autofillHints,
      textInputAction: widget.textInputAction,
      onFieldSubmitted: widget.onSubmitted,
      validator: widget.validator,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      decoration: InputDecoration(
        labelText: widget.labelText,
        errorText: widget.errorText,
        prefixIcon: const Icon(Icons.lock_outline),
        suffixIcon: IconButton(
          icon: Icon(_obscured ? Icons.visibility_off : Icons.visibility),
          tooltip: _obscured ? 'Show password' : 'Hide password',
          onPressed: widget.enabled ? _toggle : null,
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
