import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import '../../catalog/domain/product.dart';

class ProductLocalDataSource {
  static bool _isTestProduct(Product p) {
    final name = (p.name).trim().toLowerCase();
    final sku = (p.sku ?? '').trim().toLowerCase();
    return name == 'test' || sku == 'test';
  }

  Future<List<Product>> fetchProducts() async {
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
