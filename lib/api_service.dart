import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models/product.dart';
import 'models/user.dart';
import 'models/category.dart';

class ApiService {
  static const String baseUrl = 'https://qfurniture.com.au';
  static const String apiBase = '$baseUrl/wp-json';
  static const String wcApiBase = '$apiBase/wc/store/v1'; // Public API

  static String url(int nrResults) {
    return 'http://api.randomuser.me/?results=$nrResults';
  }

  static Future<List<User>> getUsers({int nrUsers = 1}) async {
    try {
      final response = await http.get(
        Uri.parse(url(nrUsers)),
      );

      if (response.statusCode == 200) {
        Map data = json.decode(response.body);
        Iterable list = data["results"];
        List<User> users = list.map((l) => User.fromJson(l)).toList();
        return users;
      } else {
        print(response.body);
        return [];
      }
    } catch (e) {
      print(e);
      return [];
    }
  }

  static Future<List<Product>> getProducts(
      {int page = 1, int perPage = 20, String? category}) async {
    try {
      String url = productsUrl(page: page, perPage: perPage);
      if (category != null && category.isNotEmpty) {
        url += '&category=$category';
      }

      final response = await http
          .get(
        Uri.parse(url),
      )
          .timeout(
        Duration(seconds: 10),
        onTimeout: () {
          throw Exception('Request timeout');
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data is List) {
          return data
              .map((item) => Product.fromApiJson(item as Map<String, dynamic>))
              .toList();
        }
      } else {
        print('API Error ${response.statusCode}: ${response.body}');
      }
      return [];
    } catch (e) {
      print('Error fetching products: $e');
      return [];
    }
  }

  static String productsUrl({int page = 1, int perPage = 20}) =>
      '$wcApiBase/products?page=$page&per_page=$perPage';

  /// Fetch all product categories
  static Future<List<Category>> getCategories({int? parent}) async {
    try {
      String url = '$wcApiBase/products/categories?per_page=100';
      if (parent != null) {
        url += '&parent=$parent';
      }

      final response = await http
          .get(
        Uri.parse(url),
      )
          .timeout(
        Duration(seconds: 10),
        onTimeout: () {
          throw Exception('Request timeout');
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data is List) {
          return data
              .map((item) => Category.fromJson(item as Map<String, dynamic>))
              .where((category) =>
                  category.count > 0) // Only show categories with products
              .toList();
        }
      } else {
        print('API Error ${response.statusCode}: ${response.body}');
      }
      return [];
    } catch (e) {
      print('Error fetching categories: $e');
      return [];
    }
  }

  /// Get products by category slug
  static Future<List<Product>> getProductsByCategory(String categorySlug,
      {int page = 1, int perPage = 20}) async {
    try {
      // First get category ID from slug
      final categories = await getCategories();
      final category = categories.firstWhere(
        (cat) => cat.slug == categorySlug,
        orElse: () => Category(id: 0, name: '', slug: '', count: 0),
      );

      if (category.id == 0) {
        return [];
      }

      return await getProducts(
          page: page, perPage: perPage, category: category.id.toString());
    } catch (e) {
      print('Error fetching products by category: $e');
      return [];
    }
  }

  /// Search products
  static Future<List<Product>> searchProducts(String query,
      {int page = 1, int perPage = 20}) async {
    try {
      final response = await http
          .get(
        Uri.parse(
            '$wcApiBase/products?search=$query&page=$page&per_page=$perPage'),
      )
          .timeout(
        Duration(seconds: 10),
        onTimeout: () {
          throw Exception('Request timeout');
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data is List) {
          return data
              .map((item) => Product.fromApiJson(item as Map<String, dynamic>))
              .toList();
        }
      }
      return [];
    } catch (e) {
      print('Error searching products: $e');
      return [];
    }
  }

  /// Get single product by ID
  static Future<Product?> getProduct(int productId) async {
    try {
      final response = await http
          .get(
        Uri.parse('$wcApiBase/products/$productId'),
      )
          .timeout(
        Duration(seconds: 10),
        onTimeout: () {
          throw Exception('Request timeout');
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return Product.fromApiJson(data as Map<String, dynamic>);
      }
      return null;
    } catch (e) {
      print('Error fetching product: $e');
      return null;
    }
  }
}
