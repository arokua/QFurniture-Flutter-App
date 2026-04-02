import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, kIsWeb;
import 'package:url_launcher/url_launcher.dart';

import '../services/auth_service.dart';
import 'store_config.dart';

/// Opens the store (WooCommerce) in the browser: add_to_cart, cart, or checkout.
/// The store/WordPress DB will receive the order when the user completes checkout on the site.
class StoreLinkService {
  /// Open store add_to_cart URL for one product. Store cart is updated; order is in WordPress when user checks out.
  static Future<bool> openAddToCart(int productId, {int quantity = 1}) async {
    final url = storeAddToCartUrl(productId, quantity: quantity);
    return _launch(url);
  }

  /// Open store cart page.
  static Future<bool> openCart() async => _launch(storeCartUrl);

  /// Open store checkout page (user must have added items on store or we open cart).
  static Future<bool> openCheckout() async => _launch(storeCheckoutUrl);

  /// Open URL that adds the first cart item to the store, then user can add more or go to checkout on the site.
  static Future<bool> openAddCartToStore(
      List<({int productId, int quantity})> items) async {
    if (items.isEmpty) return openCart();
    final url = storeAddMultipleToCartUrl(items);
    return _launch(url);
  }

  /// Opens any store URL in the **system browser** (Chrome / Safari).
  /// When the user is logged in with a JWT, uses [buildJwtCookieBridgeLaunchUrl] so the
  /// server can set cookies before redirect (same intent as WebView POST bridge).
  static Future<bool> openUrl(String url) => _launch(url);

  static String _urlWithSessionIfNeeded(String targetUrl) {
    if (!kUseJwtBridgeForExternalBrowser) return targetUrl;
    final jwt = AuthService.instance.jwtToken;
    if (jwt == null || jwt.isEmpty) return targetUrl;
    try {
      final u = Uri.parse(targetUrl);
      final store = Uri.parse(kStoreBaseUrl);
      if (u.host != store.host) return targetUrl;
      if (u.path.contains('lost-password')) return targetUrl;
    } catch (_) {
      return targetUrl;
    }
    return buildJwtCookieBridgeLaunchUrl(jwt: jwt, redirectUrl: targetUrl);
  }

  static Future<bool> _launch(String targetUrl) async {
    final resolved = _urlWithSessionIfNeeded(targetUrl);
    final uri = Uri.parse(resolved);
    try {
      if (kIsWeb) {
        return launchUrl(uri, webOnlyWindowName: '_blank');
      }
      if (kDebugMode) {
        debugPrint('[StoreLink] opening: $uri');
      }
      // Prefer the device default browser — avoids a separate in-app session vs the app cart.
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (ok) return true;
      return launchUrl(uri, mode: LaunchMode.platformDefault);
    } catch (_) {
      return false;
    }
  }

  /// WooCommerce lost password on the storefront (`/my-account/lost-password/`).
  static Future<bool> openPasswordReset() async => _launch(storeLostPasswordUrl);
}
