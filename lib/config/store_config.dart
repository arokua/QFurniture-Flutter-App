/// Store (WooCommerce) base URL. Must match fetch_woocommerce_products.py BASE_URL.
const String kStoreBaseUrl = 'https://qfurniture.com.au';

/// Paths on the store (WooCommerce default).
const String kStoreCartPath = '/cart';
const String kStoreCheckoutPath = '/checkout';

/// Build store URL for add-to-cart (single product, quantity 1).
/// WooCommerce: ?add-to-cart=ID&quantity=N on the site root.
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

/// Build store cart page URL.
String get storeCartUrl => '$kStoreBaseUrl$kStoreCartPath/';

/// Build store checkout page URL.
String get storeCheckoutUrl => '$kStoreBaseUrl$kStoreCheckoutPath/';

/// Build URL that adds multiple items to store cart.
/// Standard WooCommerce only handles one add-to-cart per request; we add first item
/// and optionally append others as repeated params (store may need plugin for multi).
String storeAddMultipleToCartUrl(List<({int productId, int quantity})> items) {
  if (items.isEmpty) return storeCartUrl;
  // Note: Standard WC doesn't natively support comma-separated IDs in GET without a plugin.
  // We use the first item as the main trigger to at least ensure one item is added upon landing.
  return storeAddToCartUrl(items.first.productId, quantity: items.first.quantity);
}
