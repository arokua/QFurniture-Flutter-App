import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/category.dart';

const _baseUrl = 'https://qtoys.com.au';
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
      final all = list
          .map((e) => Category.fromJson(e as Map<String, dynamic>))
          .toList();

      final byId = <int, Category>{for (final c in all) c.id: c};
      final allowedRootIds = all
          .where((c) => c.parent == 0 && allowedParentSlugs.contains(c.slug))
          .map((c) => c.id)
          .toSet();

      bool hasAllowedAncestor(Category c) {
        var parentId = c.parent;
        while (parentId != 0) {
          if (allowedRootIds.contains(parentId)) return true;
          final parent = byId[parentId];
          if (parent == null) return false;
          parentId = parent.parent;
        }
        return false;
      }

      final filtered = all
          .where((c) =>
              (c.parent == 0 && allowedParentSlugs.contains(c.slug)) ||
              hasAllowedAncestor(c))
          .toList();
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
      const Category(id: 1, name: 'Toys and Educational Resources', slug: 'toys-and-educational-resources', parent: 0, menuOrder: 10),
      const Category(id: 2, name: 'Furniture and Preschool Equipment', slug: 'furniture-and-preschool-equipment', parent: 0, menuOrder: 20),
      const Category(id: 3, name: 'Value Educational Packages', slug: 'bundles', parent: 0, menuOrder: 40),
      const Category(id: 4, name: 'Homewares', slug: 'homewares', parent: 0, menuOrder: 30),
      const Category(id: 5, name: 'By Age Group', slug: 'by-age-group', parent: 0, menuOrder: 15),
      const Category(id: 6, name: 'Recommended Collection', slug: 'recommended-collection', parent: 0, menuOrder: 35),
      const Category(id: 7, name: 'Clearance Sales', slug: 'clearance-sales', parent: 0, menuOrder: 36),
    ];
  }
}
