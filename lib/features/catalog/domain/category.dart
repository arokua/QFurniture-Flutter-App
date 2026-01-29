/// Category from WooCommerce Store API (products/categories).
/// Tree: parent === 0 for roots; children by parent id.
class Category {
  final int id;
  final String name;
  final String slug;
  final int parent;
  final int? menuOrder;
  final List<Category> children;

  const Category({
    required this.id,
    required this.name,
    required this.slug,
    required this.parent,
    this.menuOrder,
    this.children = const [],
  });

  factory Category.fromJson(Map<String, dynamic> j) {
    return Category(
      id: j['id'] is int ? j['id'] as int : int.tryParse(j['id'].toString()) ?? 0,
      name: _decodeHtmlEntities(j['name'] as String? ?? ''),
      slug: j['slug'] as String? ?? '',
      parent: j['parent'] is int ? j['parent'] as int : int.tryParse(j['parent'].toString()) ?? 0,
      menuOrder: j['menu_order'] as int?,
    );
  }

  static String _decodeHtmlEntities(String text) {
    return text
        .replaceAll('&#8216;', "'")
        .replaceAll('&#8217;', "'")
        .replaceAll('&amp;', '&')
        .replaceAll('&nbsp;', ' ');
  }

  Category copyWith({List<Category>? children}) {
    return Category(
      id: id,
      name: name,
      slug: slug,
      parent: parent,
      menuOrder: menuOrder,
      children: children ?? this.children,
    );
  }
}

/// Allowed parent slugs for main nav (same as reference).
const allowedParentSlugs = {
  'outdoor-furniture',
  'childrens-furniture',
  'children-furniture',
  'new-arrivals',
  'homewares',
  'indoor-dining',
};

List<Category> buildCategoryTree(List<Category> flat) {
  final map = <int, Category>{};
  for (final c in flat) {
    map[c.id] = c.copyWith(children: []);
  }
  for (final c in flat) {
    final cat = map[c.id]!;
    if (cat.parent != 0) {
      final p = map[cat.parent];
      if (p != null) p.children.add(cat);
    }
  }
  final roots = <Category>[];
  for (final c in flat) {
    if (c.parent == 0) roots.add(map[c.id]!);
  }
  for (final r in map.values) {
    if (r.children.isNotEmpty) {
      r.children.sort((a, b) => a.name.compareTo(b.name));
    }
  }
  roots.sort((a, b) => a.name.compareTo(b.name));
  return roots;
}
