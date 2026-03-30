import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../services/auth_service.dart';

class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _nameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _phoneController = TextEditingController();
  final _abnController = TextEditingController();
  final _websiteController = TextEditingController();

  bool _isLoading = false;
  String? _error;

  /// Role options: slug → display label (dropdown order: B2B first, then retail, then normal).
  static const _roleLabels = <String, String>{
    'wholesale': 'Wholesale',
    'dropshipping': 'Dropship',
    'retailer': 'Retailer',
    'customers': 'Normal',
  };

  static const _roleOrder = <String>[
    'wholesale',
    'dropshipping',
    'retailer',
    'customers',
  ];

  String _selectedRole = 'customers';

  /// Whether the selected role requires business fields.
  bool get _needsBusinessFields =>
      _selectedRole == 'wholesale' ||
      _selectedRole == 'retailer' ||
      _selectedRole == 'dropshipping';

  @override
  void dispose() {
    _emailController.dispose();
    _nameController.dispose();
    _passwordController.dispose();
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
      email: _emailController.text.trim(),
      password: _passwordController.text.trim(),
      displayName: _nameController.text.trim(),
      role: _selectedRole,
      phone: _needsBusinessFields ? _phoneController.text.trim() : null,
      abn: _needsBusinessFields ? _abnController.text.trim() : null,
      websiteUrl: _needsBusinessFields ? _websiteController.text.trim() : null,
    );

    if (mounted) {
      setState(() => _isLoading = false);
      if (result.isSuccess) {
        // Router redirect will handle navigation via refreshListenable
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
                  'Create Account',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Join the qtoys family',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 40),

                // ── Name ────────────────────────────────────────
                TextFormField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    labelText: 'First Name',
                    prefixIcon: const Icon(Icons.person_outline),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Name is required' : null,
                ),
                const SizedBox(height: 16),

                // ── Email ───────────────────────────────────────
                TextFormField(
                  controller: _emailController,
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

                // ── Password ────────────────────────────────────
                TextFormField(
                  controller: _passwordController,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  obscureText: true,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Password is required';
                    if (v.trim().length < 6) return 'At least 6 characters';
                    return null;
                  },
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
