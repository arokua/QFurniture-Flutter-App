import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app_router.dart';
import '../../../config/store_cart_api_service.dart';
import '../../../config/store_link_service.dart';
import '../../../features/cart/data/cart_provider.dart';
import 'widgets/password_field.dart';
import '../../../services/auth_service.dart';
import '../../../services/order_history_sync_service.dart';
import '../../../services/product_sync_service.dart';
import '../../../widgets/app_brand_logo.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// Opens WooCommerce's password-reset page in the system browser.
  ///
  /// Interim: a fully native reset needs `qtoys/v1/password-reset/*` endpoints
  /// that do not exist server-side yet (see localDocs/deferred-backlog.txt B7).
  /// This at least gives a locked-out user a working route — the previous link
  /// pointed at `edit-account`, which just bounced them back to sign-in.
  Future<void> _handleForgotPassword() async {
    final ok = await StoreLinkService.openPasswordReset();
    if (!mounted || ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          "We couldn't open the reset page. Please try again in a moment.",
        ),
      ),
    );
  }

  Future<void> _handleLogin() async {
    if (_isLoading) return;
    final email = _emailController.text.trim();
    // Do not trim passwords — spaces can be intentional.
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Please enter both email and password.');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    final result = await AuthService.instance.signIn(
      email: email,
      password: password,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (!result.isSuccess) {
      setState(() => _error = result.errorMessage);
      return;
    }

    await StoreCartApiService.instance
        .bootstrapSessionFromJwt(AuthService.instance.jwtToken);
    AuthService.instance.warmWebSessionCode().ignore();
    if (!mounted) return;

    await ref.read(cartProvider.notifier).syncLocalCartToStoreAfterLogin();
    if (!mounted) return;

    ProductSyncService.instance.ensureCatalogLoaded(force: true).ignore();
    OrderHistorySyncService.instance.syncNow(force: true).ignore();
    context.go(AppRoutes.home);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Logo
              const AppBrandLogo(height: 100, borderRadius: 20),
              const SizedBox(height: 32),
              Text(
                'Partner sign in',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'learning through play',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.9),
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'TWO DECADES OF ENGINEERING CHILDREN\'S DREAMS',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.6),
                  letterSpacing: 0.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 48),
              // Email field
              TextField(
                controller: _emailController,
                decoration: InputDecoration(
                  labelText: 'Email',
                  prefixIcon: const Icon(Icons.email_outlined),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 16),
              // Password field with show/hide toggle
              PasswordField(
                controller: _passwordController,
                enabled: !_isLoading,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _handleLogin(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: TextStyle(color: cs.error)),
              ],
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _isLoading ? null : _handleForgotPassword,
                  child: const Text('Forgot password?'),
                ),
              ),
              const SizedBox(height: 8),
              // Login button
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton(
                  onPressed: _isLoading ? null : _handleLogin,
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _isLoading 
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Sign in'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
