import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import '../../catalog/domain/product.dart';
import '../../../services/product_sync_service.dart';

/// Local data source that first tries the on-device ProductSyncService cache
/// (which is populated from WooCommerce on launch), then falls back to the
/// bundled asset JSON, and finally to dummy_data.json.
class ProductLocalDataSource {
  static bool _isTestProduct(Product p) {
    final name = (p.name).trim().toLowerCase();
    final sku = (p.sku ?? '').trim().toLowerCase();
    return name == 'test' || sku == 'test';
  }

  Future<List<Product>> fetchProducts() async {
    // 1. Try sync-service cache (network + SharedPreferences)
    try {
      final maps = await ProductSyncService.instance.getProducts();
      if (maps.isNotEmpty) {
        final products = <Product>[];
        for (final e in maps) {
          try {
            final p = Product.fromJson(e);
            if (!_isTestProduct(p)) products.add(p);
          } catch (_) {}
        }
        if (products.isNotEmpty) return products;
      }
    } catch (_) {}

    // 2. Fallback: bundled asset files
    for (final path in ['assets/data/products.json', 'assets/dummy_data.json']) {
      try {
        final raw = await rootBundle.loadString(path);
        final list = jsonDecode(raw) as List<dynamic>;
        final products = <Product>[];
        for (final e in list) {
          try {
            final p = Product.fromJson(e as Map<String, dynamic>);
            if (!_isTestProduct(p)) products.add(p);
          } catch (_) {
            // skip malformed product
          }
        }
        if (products.isNotEmpty) return products;
      } catch (_) {
        continue;
      }
    }
    return [];
  }

  Future<Product?> fetchById(int id) async {
    final items = await fetchProducts();
    try {
      return items.firstWhere((p) => p.id == id);
    } catch (e) {
      return null;
    }
  }
}
