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
      menuOrder: _parseOptionalInt(j['menu_order']),
    );
  }

  static String _decodeHtmlEntities(String text) {
    return text
        .replaceAll('&#8216;', "'")
        .replaceAll('&#8217;', "'")
        .replaceAll('&amp;', '&')
        .replaceAll('&nbsp;', ' ');
  }

  static int? _parseOptionalInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is String) return int.tryParse(v);
    return int.tryParse(v.toString());
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

/// Allowed parent slugs for top-level categories (legacy + Qtoys catalogue).
const allowedParentSlugs = {
  'outdoor-furniture',
  'childrens-furniture',
  'children-furniture',
  'new-arrivals',
  'sales',
  'homewares',
  'indoor-dining',
  'toys-and-educational-resources',
  'furniture-and-preschool-equipment',
  'bundles',
  'by-age-group',
};

/// Sidebar/category-tree label override for specific slugs.
String categorySidebarLabel(Category c) {
  if (c.slug == 'sales') return 'Clearance Sales';
  return c.name;
}

/// WooCommerce [menu_order]: lower first; missing order sorts last, then by name.
int _compareCategoryOrder(Category a, Category b) {
  const maxOrder = 999999;
  final ao = a.menuOrder ?? maxOrder;
  final bo = b.menuOrder ?? maxOrder;
  if (ao != bo) return ao.compareTo(bo);
  return a.name.compareTo(b.name);
}

List<Category> buildCategoryTree(
  List<Category> flat, {
  bool allowedRootsOnly = true,
}) {
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
    if (c.parent != 0) continue;
    if (allowedRootsOnly && !allowedParentSlugs.contains(c.slug)) continue;
    final node = map[c.id];
    if (node != null) roots.add(node);
  }
  for (final r in map.values) {
    if (r.children.isNotEmpty) {
      r.children.sort(_compareCategoryOrder);
    }
  }
  roots.sort(_compareCategoryOrder);
  sortRootsByAgeGroupLast(roots);
  return roots;
}

/// Puts the "By Age Group" root category last (main nav order).
void sortRootsByAgeGroupLast(List<Category> roots) {
  final idx = roots.indexWhere(
    (c) =>
        c.slug == 'by-age-group' ||
        c.name.toLowerCase().contains('by age group'),
  );
  if (idx != -1 && idx < roots.length - 1) {
    final item = roots.removeAt(idx);
    roots.add(item);
  }
}
