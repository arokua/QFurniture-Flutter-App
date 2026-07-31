import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../config/store_cart_api_service.dart';
import '../../../features/cart/data/cart_provider.dart';
import '../../../services/auth_service.dart';
import 'widgets/password_field.dart';

class RegistrationScreen extends ConsumerStatefulWidget {
  const RegistrationScreen({super.key});

  @override
  ConsumerState<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends ConsumerState<RegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _abnController = TextEditingController();
  final _websiteController = TextEditingController();

  bool _isLoading = false;
  String? _error;

  /// Partner roles only (retail consumer registration removed).
  static const _roleLabels = <String, String>{
    'wholesale': 'Wholesale',
    'dropshipping': 'Dropship / Retail',
  };

  static const _roleOrder = <String>[
    'wholesale',
    'dropshipping',
  ];

  String _selectedRole = 'wholesale';

  /// Whether the selected role requires business fields.
  bool get _needsBusinessFields =>
      _selectedRole == 'wholesale' || _selectedRole == 'dropshipping';

  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _firstNameController.dispose();
    _phoneController.dispose();
    _abnController.dispose();
    _websiteController.dispose();
    super.dispose();
  }

  Future<void> _handleRegister() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    final result = await AuthService.instance.signUp(
      username: _usernameController.text.trim(),
      email: _emailController.text.trim(),
      password: _passwordController.text.trim(),
      firstName: _firstNameController.text.trim().isEmpty
          ? null
          : _firstNameController.text.trim(),
      role: _selectedRole,
      phone: _needsBusinessFields ? _phoneController.text.trim() : null,
      abn: _needsBusinessFields ? _abnController.text.trim() : null,
      websiteUrl: _needsBusinessFields ? _websiteController.text.trim() : null,
    );

    if (mounted) {
      setState(() => _isLoading = false);
      if (result.isSuccess) {
        await StoreCartApiService.instance
            .bootstrapSessionFromJwt(AuthService.instance.jwtToken);
        await ref.read(cartProvider.notifier).syncLocalCartToStoreAfterLogin();
      } else {
        setState(() => _error = result.errorMessage);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(backgroundColor: cs.surface, elevation: 0),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Partner registration',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Wholesale or dropship / retail trade accounts',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 20),
                Material(
                  color: cs.primaryContainer.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline, color: cs.primary, size: 22),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'All new accounts are reviewed before wholesale or trade access. '
                            'Ordering may stay unavailable until your account is approved.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 28),

                // ── Username / email / password (minimum required) ─────────────
                TextFormField(
                  controller: _usernameController,
                  autofillHints: const [AutofillHints.username],
                  decoration: InputDecoration(
                    labelText: 'Username',
                    helperText: 'Your login name for the store (letters, numbers, . _ -)',
                    prefixIcon: const Icon(Icons.alternate_email),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  textCapitalization: TextCapitalization.none,
                  autocorrect: false,
                  validator: (v) {
                    final s = v?.trim() ?? '';
                    if (s.isEmpty) return 'Username is required';
                    if (s.length < 3) return 'At least 3 characters';
                    if (s.length > 60) return 'At most 60 characters';
                    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]*$').hasMatch(s)) {
                      return 'Use letters, numbers, dots, underscores, or hyphens';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                TextFormField(
                  controller: _emailController,
                  autofillHints: const [AutofillHints.email],
                  decoration: InputDecoration(
                    labelText: 'Email',
                    prefixIcon: const Icon(Icons.email_outlined),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Email is required';
                    if (!RegExp(r'^[^@]+@[^@]+\.[^@]+$').hasMatch(v.trim())) {
                      return 'Enter a valid email';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                PasswordField(
                  controller: _passwordController,
                  autofillHints: const [AutofillHints.newPassword],
                  enabled: !_isLoading,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Password is required';
                    if (v.trim().length < 6) return 'At least 6 characters';
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                TextFormField(
                  controller: _firstNameController,
                  autofillHints: const [AutofillHints.givenName],
                  decoration: InputDecoration(
                    labelText: 'First name (optional)',
                    prefixIcon: const Icon(Icons.person_outline),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 16),

                // ── Role selector ───────────────────────────────
                DropdownButtonFormField<String>(
                  value: _selectedRole,
                  decoration: InputDecoration(
                    labelText: 'Account Type',
                    prefixIcon: const Icon(Icons.badge_outlined),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  items: _roleOrder
                      .map((k) => DropdownMenuItem(
                            value: k,
                            child: Text(_roleLabels[k] ?? k),
                          ))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => _selectedRole = v);
                  },
                ),
                const SizedBox(height: 16),

                // ── Conditional business fields ─────────────────
                AnimatedSize(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  child: _needsBusinessFields
                      ? Column(
                          children: [
                            // Website / Online Platform
                            TextFormField(
                              controller: _websiteController,
                              decoration: InputDecoration(
                                labelText: 'Website / Online Platform URL',
                                prefixIcon: const Icon(Icons.language),
                                hintText: 'https://example.com',
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                              keyboardType: TextInputType.url,
                              validator: (v) {
                                if (!_needsBusinessFields) return null;
                                if (v == null || v.trim().isEmpty) {
                                  return 'Website is required for ${_roleLabels[_selectedRole]}';
                                }
                                final url = v.trim();
                                if (!url.startsWith('http://') &&
                                    !url.startsWith('https://')) {
                                  return 'Must start with http:// or https://';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 16),

                            // Phone (10 digits, AU format)
                            TextFormField(
                              controller: _phoneController,
                              decoration: InputDecoration(
                                labelText: 'Phone Number (AU)',
                                prefixIcon: const Icon(Icons.phone),
                                hintText: '04XX XXX XXX',
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                              keyboardType: TextInputType.phone,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(10),
                              ],
                              validator: (v) {
                                if (!_needsBusinessFields) return null;
                                if (v == null || v.trim().isEmpty) {
                                  return 'Phone is required for ${_roleLabels[_selectedRole]}';
                                }
                                final digits = v.trim().replaceAll(RegExp(r'\D'), '');
                                if (digits.length != 10) {
                                  return 'Must be exactly 10 digits';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 16),

                            // ABN (12 numeric digits, not starting with 0)
                            TextFormField(
                              controller: _abnController,
                              decoration: InputDecoration(
                                labelText: 'ABN',
                                prefixIcon: const Icon(Icons.numbers),
                                hintText: '12 digit ABN',
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(12),
                              ],
                              validator: (v) {
                                if (!_needsBusinessFields) return null;
                                if (v == null || v.trim().isEmpty) {
                                  return 'ABN is required for ${_roleLabels[_selectedRole]}';
                                }
                                final digits = v.trim();
                                if (digits.length != 12) {
                                  return 'ABN must be exactly 12 digits';
                                }
                                if (digits.startsWith('0')) {
                                  return 'ABN cannot start with 0';
                                }
                                if (!RegExp(r'^\d+$').hasMatch(digits)) {
                                  return 'ABN must contain only numbers';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 16),
                          ],
                        )
                      : const SizedBox.shrink(),
                ),

                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline,
                            color: cs.onErrorContainer, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: TextStyle(color: cs.onErrorContainer),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton(
                    onPressed: _isLoading ? null : _handleRegister,
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text('Register'),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
