import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/store_config.dart';
import '../features/catalog/domain/role_pricing.dart';
import '../features/catalog/utils/html_utils.dart';

/// Handles lightweight on-device sync of product metadata from the WooCommerce
/// Store API.  Images are resolved as remote URLs (displayed via
/// [cached_network_image]) so no local files need to be present.
///
/// Strategy
/// --------
/// 1. On first launch (or when the cache is stale) we fetch the full product
///    list from WooCommerce and cache the JSON in SharedPreferences.
/// 2. On subsequent launches, if the cache is fresh (< [_cacheTtlHours]) we
///    serve from cache immediately.  A background refresh still kicks off if
///    the cache is > [_backgroundRefreshHours] old.
/// 3. If offline or the request fails we fall back to the bundled
///    `assets/data/products.json`.
class ProductSyncService {
  ProductSyncService._();
  static final ProductSyncService instance = ProductSyncService._();

  static const String _cacheKey = 'qf_product_cache_v2';
  static const String _cacheTimestampKey = 'qf_product_cache_ts_v2';
  static const int _cacheTtlHours = 12;
  static const int _backgroundRefreshHours = 2;
  static const int _perPage = 100;

  static String get _remoteEndpoint => '${kStoreBaseUrl}/wp-json/wc/store/v1/products';

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Returns the best available product JSON list.
  ///
  /// Priority: fresh network → cached → bundled asset.
  Future<List<Map<String, dynamic>>> getProducts() async {
    final prefs = await SharedPreferences.getInstance();
    final cachedJson = prefs.getString(_cacheKey);
    final cachedTs = prefs.getInt(_cacheTimestampKey) ?? 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final ageHours = (nowMs - cachedTs) / (1000 * 3600);

    if (cachedJson != null && ageHours < _cacheTtlHours) {
      // Serve from cache; maybe trigger background refresh
      if (ageHours > _backgroundRefreshHours) {
        _refreshInBackground(prefs);
      }
      return _decode(cachedJson);
    }

    // Try to fetch fresh data
    try {
      final fresh = await _fetchAllRemote();
      if (fresh.isNotEmpty) {
        await _saveCache(prefs, fresh);
        return fresh;
      }
    } catch (_) {
      // ignore – fall through to cached / bundled
    }

    // Use stale cache if available
    if (cachedJson != null) return _decode(cachedJson);

    // Last resort: bundled asset
    return _loadBundledAsset();
  }

  /// Force a fresh fetch from the network and update the cache.
  Future<void> forceRefresh() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final fresh = await _fetchAllRemote();
      if (fresh.isNotEmpty) await _saveCache(prefs, fresh);
    } catch (_) {}
  }

  /// Clears the on-device cache so the next [getProducts()] call fetches fresh.
  Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey);
    await prefs.remove(_cacheTimestampKey);
  }

  // ── Private helpers ─────────────────────────────────────────────────────────

  static bool _backgroundRefreshScheduled = false;

  void _refreshInBackground(SharedPreferences prefs) {
    if (_backgroundRefreshScheduled) return;
    _backgroundRefreshScheduled = true;
    Future.microtask(() async {
      try {
        final fresh = await _fetchAllRemote();
        if (fresh.isNotEmpty) await _saveCache(prefs, fresh);
      } catch (_) {}
      _backgroundRefreshScheduled = false;
    });
  }

  Future<List<Map<String, dynamic>>> _fetchAllRemote() async {
    final List<Map<String, dynamic>> all = [];
    int page = 1;

    while (true) {
      final uri = Uri.parse(_remoteEndpoint).replace(queryParameters: {
        'page': '$page',
        'per_page': '$_perPage',
      });

      final response = await http.get(uri).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) break;

      final List<dynamic> batch =
          jsonDecode(response.body) as List<dynamic>;
      if (batch.isEmpty) break;

      all.addAll(batch.cast<Map<String, dynamic>>());

      final totalStr = response.headers['x-wp-total'];
      final totalPagesStr = response.headers['x-wp-totalpages'];
      if (totalStr != null && page == 1) {
        print('WooCommerce Store API reports $totalStr products total.');
      }

      if (totalPagesStr != null) {
        final totalPages = int.tryParse(totalPagesStr) ?? 1;
        if (page >= totalPages) break;
      }
      page++;
    }

    print('Fetched ${all.length} products total from Store API');
    return all.map(_normalizeRemoteProduct).toList();
  }

  /// Normalise the WooCommerce Store API shape into our local product shape.
  Map<String, dynamic> _normalizeRemoteProduct(Map<String, dynamic> p) {
    // Images: extract URLs from the {id,src,...} objects
    final rawImages = (p['images'] as List? ?? []);
    final imageUrls = rawImages
        .map((img) => img is Map ? (img['src'] ?? '').toString() : img.toString())
        .where((u) => u.isNotEmpty)
        .toList();

    // Categories
    final rawCats = (p['categories'] as List? ?? []);
    final cats = rawCats
        .map((c) => c is Map ? (c['name'] ?? '').toString() : c.toString())
        .where((c) => c.isNotEmpty)
        .toList();

    // Price: always output dollars so cache never has cents (avoids double-divide in fromJson on refresh).
    final pricesObj = p['prices'] as Map<String, dynamic>? ?? {};
    double parseP(dynamic v) {
      if (v == null) return 0.0;
      if (v is num) {
        final d = v.toDouble();
        if (d >= 100 && d == d.truncateToDouble()) return d / 100;
        return d;
      }
      final s = v.toString().replaceAll(RegExp(r'[^\d.]'), '');
      final d = double.tryParse(s) ?? 0.0;
      if (d >= 100 && !v.toString().contains('.')) return d / 100;
      return d;
    }

    final price = parseP(p['price'] ?? pricesObj['price']);
    final regularPrice =
        parseP(p['regular_price'] ?? pricesObj['regular_price']);
    final salePrice = parseP(p['sale_price'] ?? pricesObj['sale_price']);
    final bool onSale = p['on_sale'] == true ||
        (salePrice > 0 && regularPrice > salePrice);

    // Stock
    final stockAvail = p['stock_availability'];
    final apiStockAmountText = stockAvail is Map ? stockAvail['text']?.toString() : null;
    final stockQuantity = p['stock_quantity'];
    String? stockAmount;

    if (apiStockAmountText != null && apiStockAmountText.trim().isNotEmpty) {
      stockAmount = normalizeStockDisplay(apiStockAmountText.trim());
    } else if (stockQuantity != null) {
      final quantity = int.tryParse(stockQuantity.toString());
      if (quantity != null && quantity > 0) {
        stockAmount = '$quantity in stock';
      }
    }

    // Attributes
    String? material, color, assemblyRequired;
    for (final a in (p['attributes'] as List? ?? [])) {
      if (a is! Map) continue;
      final slug = (a['slug'] ?? a['taxonomy'] ?? '').toString().toLowerCase();
      final terms = a['terms'] as List? ?? [];
      final firstVal =
          terms.isNotEmpty && terms.first is Map ? terms.first['name']?.toString() : null;
      if (slug.contains('material')) material = firstVal;
      if (slug.contains('color') || slug.contains('colour')) color = firstVal;
      if (slug.contains('assembly')) assemblyRequired = firstVal;
    }

    String sku = (p['sku'] ?? '').toString().trim();
    if (sku.isEmpty) {
      for (final m in (p['meta_data'] as List? ?? [])) {
        if (m is! Map) continue;
        final key = m['key']?.toString().toLowerCase() ?? '';
        if (key == 'sku' || key == '_sku') {
          final v = m['value'];
          sku = v?.toString().trim() ?? '';
          if (sku.isNotEmpty) break;
        }
      }
    }
    if (sku.isEmpty) sku = '${p['id']}';

    final rolePrices = _rolePricesSnapshot(
      price: price,
      regularPrice: regularPrice,
      salePrice: salePrice,
      onSale: onSale,
    );

    return {
      'id': p['id'],
      'slug': p['slug'] ?? '',
      'name': p['name'] ?? '',
      'sku': sku,
      // Keep product permalink so the UI can open the correct product page.
      // WC store API / WP may expose it as `permalink` (preferred) or fallbacks.
      'permalink': p['permalink'] ?? p['link'] ?? p['url'] ?? p['guid'],
      'description': (p['description'] ?? '').toString().trim(),
      'shortDescription': (p['short_description'] ?? '').toString().trim(),
      'price': price,
      'regularPrice': regularPrice,
      'salePrice': salePrice,
      'onSale': onSale,
      'rolePrices': rolePrices,
      'currency': pricesObj['currency_code'] ?? 'AUD',
      'categories': cats,
      'category': cats.join(', '),
      // Use remote URLs directly – displayed via cached_network_image
      'image': imageUrls.isNotEmpty ? imageUrls.first : '',
      'images': imageUrls,
      'inStock': p['is_in_stock'] ?? true,
      'stockAmount': stockAmount,
      'material': material,
      'assemblyRequired': assemblyRequired ?? 'Yes',
      'color': color,
      'weight': p['weight']?.toString(),
      'dimensions': _formatDimensions(p['dimensions']),
      'variants': p['variations'] ?? [],
      'modified': p['date_modified_gmt'],
    };
  }

  static Map<String, dynamic> _rolePricesSnapshot({
    required double price,
    required double regularPrice,
    required double salePrice,
    required bool onSale,
  }) {
    double current() =>
        onSale && salePrice > 0 ? salePrice : price;
    double regular() => regularPrice;
    double? sale() => onSale && salePrice > 0 ? salePrice : null;

    Map<String, double> tier(double m) {
      final map = <String, double>{
        'price': RolePricing.roundMoney(current() * m),
        'regularPrice': RolePricing.roundMoney(regular() * m),
      };
      final s = sale();
      if (s != null) map['salePrice'] = RolePricing.roundMoney(s * m);
      return map;
    }

    return {
      'retailer': tier(1.0),
      'wholesale': tier(0.5),
      'dropship': tier(0.55),
      'admin': tier(0.75),
    };
  }

  String? _formatDimensions(dynamic dim) {
    if (dim == null) return null;
    if (dim is String) return dim.trim().isEmpty ? null : dim.trim();
    if (dim is Map) {
      final parts = ['length', 'width', 'height']
          .map((k) => dim[k]?.toString().trim() ?? '')
          .where((v) => v.isNotEmpty)
          .toList();
      return parts.isEmpty ? null : parts.join(' x ');
    }
    return null;
  }

  Future<void> _saveCache(
      SharedPreferences prefs, List<Map<String, dynamic>> products) async {
    final json = jsonEncode(products);
    await prefs.setString(_cacheKey, json);
    await prefs.setInt(
        _cacheTimestampKey, DateTime.now().millisecondsSinceEpoch);
  }

  List<Map<String, dynamic>> _decode(String json) {
    try {
      final list = jsonDecode(json) as List<dynamic>;
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _loadBundledAsset() async {
    for (final path in [
      'assets/data/products.json',
      'assets/dummy_data.json',
    ]) {
      try {
        final raw = await rootBundle.loadString(path);
        final list = jsonDecode(raw) as List<dynamic>;
        return list.cast<Map<String, dynamic>>();
      } catch (_) {}
    }
    return [];
  }
}
