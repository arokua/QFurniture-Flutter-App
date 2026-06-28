import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:url_launcher/url_launcher.dart';

import '../app_router.dart';
import '../config/post_checkout_destination_preference.dart';
import '../config/store_config.dart';
import '../services/auth_service.dart';

/// Navigate after checkout using the user's Profile preference.
class PostCheckoutNavigation {
  PostCheckoutNavigation._();

  static bool _handled = false;

  /// Reset between checkout attempts (e.g. new WebView session).
  static void reset() => _handled = false;

  static void go([PostCheckoutDestination? destination]) {
    if (_handled) return;
    _handled = true;

    final dest = destination ?? PostCheckoutDestinationPreference.current;
    switch (dest) {
      case PostCheckoutDestination.catalog:
        router.go(AppRoutes.home);
      case PostCheckoutDestination.orderHistory:
        router.go(AppRoutes.orders);
      case PostCheckoutDestination.myAccountDashboard:
        router.go(AppRoutes.home);
        Future.microtask(() => _openStoreWebView(storeMyAccountUrl));
    }
  }

  static void _openStoreWebView(String url) {
    if (kIsWeb) {
      launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
      return;
    }
    final signedIn = AuthService.instance.currentSession != null;
    router.push(
      Uri(
        path: AppRoutes.store,
        queryParameters: {
          'url': url,
          if (signedIn) 'autologin': '1',
          'mobile': '1',
        },
      ).toString(),
    );
  }
}
