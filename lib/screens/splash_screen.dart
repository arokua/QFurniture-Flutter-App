import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../app_router.dart';
import '../services/auth_service.dart';
import '../services/product_sync_service.dart';
import '../services/order_history_sync_service.dart';
import '../config/store_cart_api_service.dart';

/// Branded splash screen showing the qtoys logo (QIcon2.png).
/// Waits for the first product batch (or a short timeout) before opening the catalog.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();

    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);
    _scale = Tween<double>(begin: 0.82, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack),
    );

    _ctrl.forward();
    _navigateWhenReady();
  }

  Future<void> _navigateWhenReady() async {
    final auth = AuthService.instance;

    // Started before the splash floor rather than after it, so the catalogue
    // loads during the animation instead of beginning once it ends.
    final sync = ProductSyncService.instance;
    sync.ensureCatalogLoaded().ignore();

    // Signing in is no longer a precondition for reaching the app, so session
    // recovery runs alongside the splash instead of gating it.
    if (auth.isSignedIn) {
      _resumeSessionInBackground(auth).ignore();
    }

    // Minimum splash time so the logo doesn't flicker.
    await Future.delayed(const Duration(milliseconds: 900));

    final deadline = DateTime.now().add(const Duration(seconds: 4));
    while (!sync.initialBatchReady && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 50));
    }

    if (!mounted) return;
    // Guests land here too; the router gates the routes that need an identity.
    context.go(AppRoutes.home);
  }

  /// Session work that used to block navigation.
  ///
  /// Nothing here gates the UI. If the session turns out to be unrecoverable
  /// `AuthService` signs out, and the router's `refreshListenable` redirects
  /// from wherever the user has already landed.
  Future<void> _resumeSessionInBackground(AuthService auth) async {
    if (!await auth.ensureValidSession()) return;
    // Re-prime Woo cart session cookies after token refresh on cold start.
    await StoreCartApiService.instance.bootstrapSessionFromJwt(auth.jwtToken);
    auth.warmWebSessionCode().ignore();
    OrderHistorySyncService.instance.syncNow(force: true).ignore();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  static const _brandGreen = Color(0xFF8BC34A); // logo + spinner only
  static const _splashBackground = Color(0xFFFDF8F0);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ProductSyncService.instance,
      builder: (context, _) {
        final sync = ProductSyncService.instance;
        return Scaffold(
      backgroundColor: _splashBackground,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        color: _splashBackground,
        child: Center(
          child: FadeTransition(
            opacity: _fade,
            child: ScaleTransition(
              scale: _scale,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Image.asset(
                      'assets/data/QIcon2.png',
                      width: 180,
                      height: 180,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => _buildFallback(),
                    ),
                  ),
                  const SizedBox(height: 28),
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: _brandGreen,
                    ),
                  ),
                  if (sync.statusMessage != null) ...[
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        sync.statusMessage!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.black.withValues(alpha: 0.55),
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
      },
    );
  }

  Widget _buildFallback() {
    return Container(
      width: 180,
      height: 180,
      decoration: BoxDecoration(
        color: _brandGreen.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(24),
      ),
      child: const Icon(Icons.chair_alt, size: 90, color: _brandGreen),
    );
  }
}
