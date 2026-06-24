import 'category.dart';
import 'product.dart';

/// Selected category for catalogue filtering (id + display label).
class SelectedCategory {
  const SelectedCategory({required this.id, required this.name});

  final int id;
  final String name;
}

/// Normalize category strings for matching (handles apostrophes, case, spaces).
String normalizeCategoryName(String s) {
  if (s.isEmpty) return '';
  return s
      .trim()
      .toLowerCase()
      .replaceAll("'", '')
      .replaceAll('\u2019', '')
      .replaceAll('\u2018', '')
      .replaceAll(RegExp(r'\s+'), ' ');
}

/// Index built from the flat category list: descendant-aware product matching.
class CategoryFilterIndex {
  CategoryFilterIndex._({
    required this.byId,
    required this.matchNamesByCategoryId,
    required this.idByNormalizedName,
    required this.roots,
  });

  final Map<int, Category> byId;
  final Map<int, Set<String>> matchNamesByCategoryId;
  final Map<String, int> idByNormalizedName;
  final List<Category> roots;

  static CategoryFilterIndex fromFlat(List<Category> flat) {
    final byId = {for (final c in flat) c.id: c};
    final childrenByParent = <int, List<Category>>{};
    for (final c in flat) {
      childrenByParent.putIfAbsent(c.parent, () => []).add(c);
    }

    final matchNamesByCategoryId = <int, Set<String>>{};

    void collectNames(int id, Set<String> out) {
      final cat = byId[id];
      if (cat == null) return;
      out.add(normalizeCategoryName(cat.name));
      for (final child in childrenByParent[id] ?? const <Category>[]) {
        collectNames(child.id, out);
      }
    }

    for (final id in byId.keys) {
      final names = <String>{};
      collectNames(id, names);
      matchNamesByCategoryId[id] = names;
    }

    final idByNormalizedName = <String, int>{};
    for (final c in flat) {
      idByNormalizedName[normalizeCategoryName(c.name)] = c.id;
    }

    final roots = buildCategoryTree(flat, allowedRootsOnly: true);
    return CategoryFilterIndex._(
      byId: byId,
      matchNamesByCategoryId: matchNamesByCategoryId,
      idByNormalizedName: idByNormalizedName,
      roots: roots,
    );
  }

  SelectedCategory? resolveByName(String name) {
    final norm = normalizeCategoryName(name);
    final id = idByNormalizedName[norm];
    if (id == null) return null;
    final cat = byId[id];
    if (cat == null) return null;
    return SelectedCategory(id: id, name: cat.name);
  }

  SelectedCategory forCategory(Category c) =>
      SelectedCategory(id: c.id, name: c.name);

  bool productMatches(Product p, SelectedCategory selected) {
    final names = matchNamesByCategoryId[selected.id];
    if (names == null || names.isEmpty) {
      return normalizeCategoryName(p.category) ==
          normalizeCategoryName(selected.name);
    }
    for (final c in p.categoryList) {
      if (names.contains(normalizeCategoryName(c))) return true;
    }
    if (p.category.isNotEmpty) {
      for (final part in p.category.split(',')) {
        if (names.contains(normalizeCategoryName(part))) return true;
      }
    }
    return false;
  }
}
