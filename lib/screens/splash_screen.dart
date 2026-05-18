import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../app_router.dart';
import '../services/product_sync_service.dart';

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
    final sync = ProductSyncService.instance;
    final syncFuture = sync.ensureCatalogLoaded();
    final minSplash = Future.delayed(const Duration(milliseconds: 1600));
    final deadline = DateTime.now().add(const Duration(seconds: 8));

    await minSplash;
    while (!sync.initialBatchReady && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 80));
    }
    await syncFuture.catchError((_) {});

    if (!mounted) return;
    context.go(AppRoutes.home);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  static const _brandGreen = Color(0xFF8BC34A);

  @override
  Widget build(BuildContext context) {
    final sync = ProductSyncService.instance;
    return Scaffold(
      backgroundColor: _brandGreen,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        color: _brandGreen,
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
                      color: Colors.white,
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
                          color: Colors.white.withValues(alpha: 0.92),
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
  }

  Widget _buildFallback() {
    return Container(
      width: 180,
      height: 180,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(24),
      ),
      child: const Icon(Icons.chair_alt, size: 90, color: Colors.white),
    );
  }
}
