import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Store (WooCommerce) base URL. Must match fetch_woocommerce_products.py BASE_URL.
String get kStoreBaseUrl => dotenv.env['STORE_BASE_URL'] ?? 'https://qtoys.com.au';

/// WooCommerce API credentials (optional, read from .env)
String get kWooKey => dotenv.env['WOO_KEY'] ?? '';
String get kWooSecret => dotenv.env['WOO_SECRET'] ?? '';

/// Site-level JWT token from .env (JWT_TOKEN in wp-config.php JWT_AUTH_SECRET_KEY).
/// Used for admin-scoped REST API calls (e.g. customer registration) so
/// wp-cerber recognises the request as authenticated app traffic.
String get kSiteJwtToken => dotenv.env['JWT_TOKEN'] ?? '';

/// Paths on the store (WooCommerce default).
const String kStoreCartPath = '/cart';
const String kStoreCheckoutPath = '/checkout';
const String kStoreMyAccountPath = '/my-account';
/// Custom add-on endpoint: validates JWT then sets WP/Woo auth cookies for WebView.
const String kJwtCookieBridgePath = '/wp-json/qtoys/v1/mobile-session';

/// Build store URL for add_to_cart (single product, quantity 1).
/// WooCommerce: ?add_to_cart=ID&quantity=N on the site root.
String storeAddToCartUrl(int productId, {int quantity = 1}) {
  if (quantity <= 0) return '$kStoreBaseUrl/';
  final uri = Uri.parse('$kStoreBaseUrl/').replace(
    queryParameters: {
      'add-to-cart': productId.toString(),
      if (quantity > 1) 'quantity': quantity.toString(),
    },
  );
  return uri.toString();
}

/// Build store URL for the product page.
///
/// Note: Prefer using the product JSON's `permalink` when available.
/// This is a fallback that uses WordPress post-by-id routing (`?p=ID`),
/// which should redirect to the product's real permalink.
String storeProductUrl(int productId) {
  if (productId <= 0) return '$kStoreBaseUrl/';
  return Uri.parse('$kStoreBaseUrl/').replace(
    queryParameters: {'p': productId.toString()},
  ).toString();
}

/// Build store cart page URL.
String get storeCartUrl => '$kStoreBaseUrl$kStoreCartPath/';

/// Build store checkout page URL.
String get storeCheckoutUrl => '$kStoreBaseUrl$kStoreCheckoutPath/';
String get jwtCookieBridgeUrl => '$kStoreBaseUrl$kJwtCookieBridgePath';

/// When opening the **system browser**, use the same JWT→cookie bridge as the WebView POST,
/// but as a GET so the server can `Set-Cookie` then redirect. The WordPress handler must accept
/// `token` + `redirect_to` (absolute URL on the store). If not implemented, set
/// [kUseJwtBridgeForExternalBrowser] to false in `.env`.
bool get kUseJwtBridgeForExternalBrowser =>
    (dotenv.env['STORE_USE_JWT_BRIDGE_EXTERNAL'] ?? 'true').toLowerCase() == 'true';

/// GET variant of [jwtCookieBridgeUrl]: `?token=...&redirect_to=...`
String buildJwtCookieBridgeLaunchUrl({
  required String jwt,
  required String redirectUrl,
}) {
  final parsed = Uri.tryParse(redirectUrl);
  final redirectPath = parsed == null
      ? null
      : parsed.path + (parsed.hasQuery ? '?${parsed.query}' : '');

  // Some WordPress handlers expect different parameter names (redirect,
  // redirectUrl, redirect_path, etc.). Sending a few aliases prevents the
  // backend from using its fallback route (which could be `/wp-json/qtoys/cart`).
  return Uri.parse(jwtCookieBridgeUrl).replace(queryParameters: {
    'token': jwt,
    'redirect_to': redirectUrl,
    'redirect': redirectUrl,
    'redirectUrl': redirectUrl,
    if (redirectPath != null) 'redirect_path': redirectPath,
    'source': 'flutter_app',
  }).toString();
}

/// Customer account dashboard (not wp-admin).
String get storeMyAccountUrl => '$kStoreBaseUrl$kStoreMyAccountPath/';

/// WooCommerce my-account login form: `?action=login` plus optional `type`:
/// wholesale | dropship | customer (dropship covers retailer + dropship in your store).
String storeMyAccountLoginUrl({String? accountType}) {
  final q = <String, String>{'action': 'login'};
  if (accountType != null && accountType.isNotEmpty) {
    q['type'] = accountType;
  }
  return Uri.parse('$kStoreBaseUrl$kStoreMyAccountPath/').replace(queryParameters: q).toString();
}

/// Lost password on storefront (not wp-login.php).
String get storeLostPasswordUrl =>
    '$kStoreBaseUrl$kStoreMyAccountPath/edit-account/';

/// Single order details in WooCommerce my account.
String storeOrderViewUrl(int orderId) =>
    '$kStoreBaseUrl$kStoreMyAccountPath/view-order/$orderId/';

/// Wholesale (B2B) minimum order — first completed order uses [kWholesaleMinimumFirstOrderAud],
/// subsequent orders use [kWholesaleMinimumReturningOrderAud] (enforced in cart before checkout).
const double kWholesaleMinimumFirstOrderAud = 500.0;
const double kWholesaleMinimumReturningOrderAud = 350.0;

/// Build URL that adds multiple items to store cart.
/// Standard WooCommerce only handles one add_to_cart per request; we add first item
/// and optionally append others as repeated params (store may need plugin for multi).
String storeAddMultipleToCartUrl(List<({int productId, int quantity})> items) {
  if (items.isEmpty) return storeCartUrl;
  // Note: Standard WC doesn't natively support comma-separated IDs in GET without a plugin.
  // We use the first item as the main trigger to at least ensure one item is added upon landing.
  return storeAddToCartUrl(items.first.productId, quantity: items.first.quantity);
}
