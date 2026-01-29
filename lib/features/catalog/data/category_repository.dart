import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/category.dart';

const _baseUrl = 'https://qfurniture.com.au';
const _categoriesEndpoint = '$_baseUrl/wp-json/wc/store/v1/products/categories';

class CategoryRepository {
  Future<List<Category>> fetchCategories() async {
    try {
      final res = await http.get(Uri.parse(_categoriesEndpoint)).timeout(
        const Duration(seconds: 15),
      );
      if (res.statusCode != 200) return _fallbackCategories();
      final list = jsonDecode(res.body) as List<dynamic>?;
      if (list == null || list.isEmpty) return _fallbackCategories();
      final mapped = list
          .map((e) => Category.fromJson(e as Map<String, dynamic>))
          .where((c) => c.parent == 0 && allowedParentSlugs.contains(c.slug) || c.parent != 0)
          .toList();
      final parentIds = mapped.where((c) => c.parent == 0 && allowedParentSlugs.contains(c.slug)).map((c) => c.id).toSet();
      final filtered = mapped.where((c) => c.parent == 0 && allowedParentSlugs.contains(c.slug) || parentIds.contains(c.parent)).toList();
      return filtered.isEmpty ? _fallbackCategories() : filtered;
    } catch (_) {
      return _fallbackCategories();
    }
  }

  /// Returns category tree (roots with children) for display.
  Future<List<Category>> getCategoryTree() async {
    final flat = await fetchCategories();
    return buildCategoryTree(flat);
  }

  List<Category> _fallbackCategories() {
    return [
      const Category(id: 1, name: 'Outdoor Furniture', slug: 'outdoor-furniture', parent: 0),
      const Category(id: 2, name: 'Children\'s Furniture', slug: 'children-furniture', parent: 0),
      const Category(id: 3, name: 'New Arrivals', slug: 'new-arrivals', parent: 0),
      const Category(id: 4, name: 'Homewares', slug: 'homewares', parent: 0),
      const Category(id: 5, name: 'Indoor Dining', slug: 'indoor-dining', parent: 0),
    ];
  }
}
