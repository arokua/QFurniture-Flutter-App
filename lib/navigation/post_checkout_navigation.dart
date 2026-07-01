import '../app_router.dart';

/// After checkout completes, return to the catalogue (main screen).
class PostCheckoutNavigation {
  PostCheckoutNavigation._();

  static bool _handled = false;

  static void reset() => _handled = false;

  static void go() {
    if (_handled) return;
    _handled = true;
    router.go(AppRoutes.home);
  }
}
