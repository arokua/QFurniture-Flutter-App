import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../app_router.dart';
import '../services/auth_service.dart';
import '../services/product_sync_service.dart';
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
    // Minimum splash time so the logo doesn't flicker.
    await Future.delayed(const Duration(milliseconds: 900));

    // Hard lock: no stored session → login first and foremost.
    if (!auth.isSignedIn) {
      if (!mounted) return;
      context.go(AppRoutes.login);
      return;
    }

    // Catalogue bootstrap + session validation in parallel.
    final sync = ProductSyncService.instance;
    sync.ensureCatalogLoaded().ignore();
    final sessionOkFuture = auth.ensureValidSession();

    final deadline = DateTime.now().add(const Duration(seconds: 4));
    while (!sync.initialBatchReady && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 50));
    }

    final sessionOk = await sessionOkFuture;
    if (!mounted) return;
    if (!sessionOk) {
      context.go(AppRoutes.login);
      return;
    }

    // Re-prime Woo cart session cookies after token refresh on cold start.
    await StoreCartApiService.instance
        .bootstrapSessionFromJwt(auth.jwtToken);
    auth.warmWebSessionCode().ignore();

    if (!mounted) return;
    context.go(AppRoutes.home);
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
