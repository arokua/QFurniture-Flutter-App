import 'package:url_launcher/url_launcher.dart';

import 'store_config.dart';

/// Opens the store (WooCommerce) in the browser: add-to-cart, cart, or checkout.
/// The store/WordPress DB will receive the order when the user completes checkout on the site.
class StoreLinkService {
  /// Open store add-to-cart URL for one product. Store cart is updated; order is in WordPress when user checks out.
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

  static Future<bool> _launch(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    return false;
  }
}
