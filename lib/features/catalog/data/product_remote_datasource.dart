import 'dart:convert';
import 'package:http/http.dart' as http;
import '../domain/product.dart';
import '../../../../config/store_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final productRemoteProvider = Provider((ref) => ProductRemoteDataSource());

class ProductRemoteDataSource {
  static const String _endpoint = '$kStoreBaseUrl/wp-json/wc/store/v1/products';

  Future<List<Product>> fetchProducts({int page = 1, int perPage = 100}) async {
    final uri = Uri.parse(_endpoint).replace(
      queryParameters: {
        'page': page.toString(),
        'per_page': perPage.toString(),
      },
    );

    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 30));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((json) {
          // Normalize API response to match our internal Product model if needed
          // The Product.fromJson already handles much of the WooCommerce Store API shape
          return Product.fromJson(json as Map<String, dynamic>);
        }).toList();
      } else {
        throw Exception('Failed to load products: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error fetching products: $e');
    }
  }

  Future<Product?> fetchById(int id) async {
    final uri = Uri.parse('$_endpoint/$id');
    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        return Product.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
      }
      return null;
    } catch (e) {
      return null;
    }
  }
}
