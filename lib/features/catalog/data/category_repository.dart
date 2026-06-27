import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../config/store_config.dart';
import '../../../services/auth_service.dart';
import '../domain/category.dart';

const _baseUrl = 'https://qtoys.com.au';
const _categoriesEndpoint = '$_baseUrl/wp-json/wc/store/v1/products/categories';

class CategoryRepository {
  static final Map<String, int> _slugIdCache = {};

  Set<String> get _allowedRootSlugs => allowedParentSlugsForRole(
        AuthService.instance.currentSession?.role,
      );

  /// Fetches every category page from the Store API (WC defaults to ~10–100 per page).
  Future<List<Category>> fetchCategories() async {
    try {
      final all = await _fetchAllCategoryPages();
      if (all.isEmpty) return _fallbackCategories();

      final allowedRoots = _allowedRootSlugs;
      final allowedRootIds = all
          .where((c) => c.parent == 0 && allowedRoots.contains(c.slug))
          .map((c) => c.id)
          .toSet();

      final allowedIds = <int>{};
      for (final rootId in allowedRootIds) {
        allowedIds.addAll(_collectDescendantIds(rootId, all));
      }

      final filtered = all.where((c) => allowedIds.contains(c.id)).toList();
      return filtered.isEmpty ? _fallbackCategories() : filtered;
    } catch (_) {
      return _fallbackCategories();
    }
  }

  Future<List<Category>> _fetchAllCategoryPages() async {
    final all = <Category>[];
    var page = 1;
    var totalPages = 1;

    while (page <= totalPages) {
      final uri = Uri.parse(_categoriesEndpoint).replace(
        queryParameters: {'page': '$page', 'per_page': '100'},
      );
      final res = await http
          .get(uri, headers: {'User-Agent': kAppUserAgent})
          .timeout(const Duration(seconds: 20));

      if (res.statusCode != 200) break;

      final list = jsonDecode(res.body) as List<dynamic>?;
      if (list == null || list.isEmpty) break;

      all.addAll(
        list.map((e) => Category.fromJson(e as Map<String, dynamic>)),
      );

      totalPages = int.tryParse(res.headers['x-wp-totalpages'] ?? '') ?? page;
      if (list.length < 100) break;
      page++;
    }

    return all;
  }

  static Set<int> _collectDescendantIds(int rootId, List<Category> all) {
    final childrenByParent = <int, List<Category>>{};
    for (final c in all) {
      childrenByParent.putIfAbsent(c.parent, () => []).add(c);
    }

    final ids = <int>{};
    void walk(int id) {
      if (!ids.add(id)) return;
      for (final child in childrenByParent[id] ?? const <Category>[]) {
        walk(child.id);
      }
    }

    walk(rootId);
    return ids;
  }

  /// Returns category tree (roots with children) for display.
  Future<List<Category>> getCategoryTree() async {
    final flat = await fetchCategories();
    return buildCategoryTree(
      flat,
      allowedRootsOnly: true,
      allowedRootSlugs: _allowedRootSlugs,
    );
  }

  Future<int?> resolveCategoryIdBySlug(String slug) async {
    final resolved = await resolveCategoryBySlug(slug);
    return resolved?.id;
  }

  /// Resolve Store API category id + display name by slug.
  Future<({int id, String name})?> resolveCategoryBySlug(String slug) async {
    final cached = _slugIdCache[slug];
    if (cached != null && cached > 0) {
      return (id: cached, name: _cachedNameForSlug(slug));
    }
    try {
      final uri = Uri.parse(_categoriesEndpoint).replace(
        queryParameters: {'slug': slug, 'per_page': '1'},
      );
      final res = await http
          .get(uri, headers: {'User-Agent': kAppUserAgent})
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      final list = jsonDecode(res.body) as List<dynamic>?;
      if (list == null || list.isEmpty) return null;
      final first = list.first;
      if (first is! Map<String, dynamic>) return null;
      final cat = Category.fromJson(first);
      if (cat.id <= 0) return null;
      _slugIdCache[slug] = cat.id;
      _slugNameCache[slug] = cat.name;
      return (id: cat.id, name: cat.name);
    } catch (_) {
      return null;
    }
  }

  static final Map<String, String> _slugNameCache = {};

  static String _cachedNameForSlug(String slug) {
    if (slug == kInitialSyncCategorySlug) return "What's New";
    return _slugNameCache[slug] ?? slug;
  }

  List<Category> _fallbackCategories() {
    return [
      const Category(id: 1, name: 'Toys and Educational Resources', slug: 'toys-and-educational-resources', parent: 0, menuOrder: 10),
      const Category(id: 2, name: 'Furniture and Preschool Equipment', slug: 'furniture-and-preschool-equipment', parent: 0, menuOrder: 20),
      const Category(id: 3, name: 'Value Educational Packages', slug: 'bundles', parent: 0, menuOrder: 40),
      const Category(id: 4, name: 'Homewares', slug: 'homewares', parent: 0, menuOrder: 30),
      const Category(id: 5, name: 'By Age Group', slug: 'by-age-group', parent: 0, menuOrder: 15),
      const Category(id: 6, name: 'Recommended Collection', slug: 'recommended-collection', parent: 0, menuOrder: 35),
      const Category(id: 7, name: 'Clearance Sales', slug: 'sales', parent: 0, menuOrder: 36),
    ];
  }
}
