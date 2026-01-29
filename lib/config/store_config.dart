/// Store (WooCommerce) base URL. Must match fetch_woocommerce_products.py BASE_URL.
const String kStoreBaseUrl = 'https://qfurniture.com.au';

/// Paths on the store (WooCommerce default).
const String kStoreCartPath = '/cart';
const String kStoreCheckoutPath = '/checkout';

/// Build store URL for add-to-cart (single product, quantity 1).
/// WooCommerce: ?add-to-cart=PRODUCT_ID
String storeAddToCartUrl(int productId, {int quantity = 1}) {
  if (quantity <= 0) return '$kStoreBaseUrl$kStoreCartPath';
  final uri = Uri.parse(kStoreBaseUrl).replace(
    queryParameters: {'add-to-cart': productId.toString()},
  );
  String url = uri.toString();
  // Some setups support quantity: repeat param or use quantity= (theme-dependent)
  if (quantity > 1) {
    url = '$url&quantity=$quantity';
  }
  return url;
}

/// Build store cart page URL.
String get storeCartUrl => '$kStoreBaseUrl$kStoreCartPath';

/// Build store checkout page URL.
String get storeCheckoutUrl => '$kStoreBaseUrl$kStoreCheckoutPath';

/// Build URL that adds multiple items to store cart.
/// Standard WooCommerce only handles one add-to-cart per request; we add first item
/// and optionally append others as repeated params (store may need plugin for multi).
String storeAddMultipleToCartUrl(List<({int productId, int quantity})> items) {
  if (items.isEmpty) return storeCartUrl;
  final params = <String, String>{
    'add-to-cart': items.first.productId.toString(),
  };
  if (items.first.quantity > 1) {
    params['quantity'] = items.first.quantity.toString();
  }
  final uri = Uri.parse(kStoreBaseUrl).replace(queryParameters: params);
  return uri.toString();
}
