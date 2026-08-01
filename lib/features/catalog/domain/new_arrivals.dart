import '../domain/product.dart';

/// How many products the New Arrivals tab shows.
const kNewArrivalsLimit = 20;

/// Latest [limit] single-SKU products by publish date (bundles/packages excluded).
/// Out-of-stock items are pushed after in-stock within the newest ordering.
List<Product> pickNewArrivals(
  List<Product> products, {
  int limit = kNewArrivalsLimit,
}) {
  final filtered =
      products.where((p) => !p.isBundleOrPackage).toList(growable: false);
  final sorted = List<Product>.from(filtered);
  sorted.sort((a, b) {
    if (a.inStock != b.inStock) return a.inStock ? -1 : 1;
    final byDate = b.newestSortKey.compareTo(a.newestSortKey);
    if (byDate != 0) return byDate;
    return b.id.compareTo(a.id);
  });
  if (sorted.length <= limit) return sorted;
  return sorted.sublist(0, limit);
}
