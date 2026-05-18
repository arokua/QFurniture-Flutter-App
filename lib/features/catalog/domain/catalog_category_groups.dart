import 'product.dart';

/// One expandable section on the catalog screen (three mains → subcategory chips).
class CatalogCategorySection {
  final String title;
  final List<String> names;

  const CatalogCategorySection({
    required this.title,
    required this.names,
  });
}

/// Buckets product category labels into three high-level groups for cleaner filtering UI.
List<CatalogCategorySection> groupCatalogCategories(List<String> all) {
  final toys = <String>[];
  final furniture = <String>[];
  final homewares = <String>[];

  for (final c in all) {
    switch (_groupIndexForLabel(c)) {
      case 0:
        toys.add(c);
        break;
      case 1:
        furniture.add(c);
        break;
      case 2:
        homewares.add(c);
        break;
    }
  }

  void sortGroup(List<String> list) {
    list.sort((a, b) {
      final mainA = kMainCategories.contains(a);
      final mainB = kMainCategories.contains(b);
      if (mainA && !mainB) return -1;
      if (!mainA && mainB) return 1;
      return a.compareTo(b);
    });
  }

  sortGroup(toys);
  sortGroup(furniture);
  sortGroup(homewares);

  final out = <CatalogCategorySection>[];
  if (toys.isNotEmpty) {
    out.add(CatalogCategorySection(title: 'Toys & Educational', names: toys));
  }
  if (furniture.isNotEmpty) {
    out.add(
        CatalogCategorySection(title: 'Furniture & Preschool', names: furniture));
  }
  if (homewares.isNotEmpty) {
    out.add(CatalogCategorySection(title: 'Homewares & More', names: homewares));
  }
  return out;
}

/// 0 = toys / educational, 1 = furniture, 2 = homewares & bundles / other retail.
int _groupIndexForLabel(String c) {
  final l = c.toLowerCase();
  if (l.contains('furniture') ||
      l.contains('preschool equipment') ||
      (l.contains('outdoor') && l.contains('furniture'))) {
    return 1;
  }
  if (l.contains('homeware') ||
      l.contains('bundle') ||
      l.contains('package') ||
      l.contains('value educational')) {
    return 2;
  }
  return 0;
}
