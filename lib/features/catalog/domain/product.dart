import '../utils/html_utils.dart';

class Variant {
  final String sku;
  final String label;
  final double price;
  final bool inStock;
  const Variant(
      {required this.sku,
      required this.label,
      required this.price,
      required this.inStock});

  factory Variant.fromJson(Map<String, dynamic> j) => Variant(
        sku: j['sku'] as String,
        label: j['label'] as String,
        price: (j['price'] as num).toDouble(),
        inStock: j['inStock'] as bool,
      );
}

/// Main catalogue categories used for filtering (same as elsewhere in the app).
const List<String> kMainCategories = [
  "Homewares",
  "Children's Furniture",
  "Outdoor Furniture",
];

class Product {
  final int id;
  final String name;
  final double price;
  final double? regularPrice;
  final double? salePrice;
  final bool onSale;
  final String currency;
  final String image;
  final List<String> images; // Multiple images for gallery
  final bool inStock;
  final String? stockAmount; // e.g. "18 in stock"
  final String category;
  final List<String>
      categoryList; // Individual categories (from categories array or split)
  final String age;
  final String description;
  final String? sku; // Product SKU
  final List<Variant> variants;
  // Additional info (detail screen)
  final String? material; // pa_material
  final String assemblyRequired; // "Yes" / "No" (Homewares → No, else Yes)
  final String? color;
  final String? weight;
  final String? dimensions;

  const Product({
    required this.id,
    required this.name,
    required this.price,
    this.regularPrice,
    this.salePrice,
    this.onSale = false,
    required this.currency,
    required this.image,
    required this.images,
    required this.inStock,
    this.stockAmount,
    required this.category,
    required this.categoryList,
    required this.age,
    required this.description,
    this.sku,
    required this.variants,
    this.material,
    this.assemblyRequired = 'Yes',
    this.color,
    this.weight,
    this.dimensions,
  });

  factory Product.fromJson(Map<String, dynamic> j) {
    // id: int or string (WooCommerce can return string)
    int id = 0;
    final idVal = j['id'];
    if (idVal is int) {
      id = idVal;
    } else if (idVal is String) {
      id = int.tryParse(idVal) ?? 0;
    }

    final imageList = j['images'] as List?;
    final imageStr = j['image'] as String? ?? '';
    final rawPrice = j['price'] ?? j['regularPrice'] ?? j['salePrice'];
    final num? priceNum = rawPrice is num ? rawPrice : null;
    final double price = priceNum != null ? (priceNum / 100).toDouble() : 0.0;
    final rawReg = j['regularPrice'];
    final num? regNum = rawReg is num ? rawReg : null;
    final double? regularPrice =
        regNum != null ? (regNum / 100).toDouble() : null;
    final rawSale = j['salePrice'];
    final num? saleNum = rawSale is num ? rawSale : null;
    final double? salePrice =
        saleNum != null ? (saleNum / 100).toDouble() : null;
    final bool onSale = j['onSale'] as bool? ?? false;

    // categoryList: from categories array (strings or {name: "x"}) or split category string; decode HTML entities
    List<String> categoryList = [];
    final cats = j['categories'] as List?;
    if (cats != null && cats.isNotEmpty) {
      for (final c in cats) {
        if (c is String && c.isNotEmpty) {
          categoryList.add(decodeHtmlEntities(c));
        } else if (c is Map && c['name'] != null) {
          categoryList.add(decodeHtmlEntities(c['name'].toString()));
        }
      }
    }
    String category = decodeHtmlEntities(j['category'] as String? ?? '');
    if (category.isEmpty && categoryList.isNotEmpty) {
      category = categoryList.join(', ');
    }
    if (categoryList.isEmpty && category.isNotEmpty) {
      categoryList = category
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }

    final Object? skuVal = j['sku'];
    final String skuResolved =
        (skuVal != null && skuVal.toString().trim().isNotEmpty)
            ? skuVal.toString().trim()
            : id.toString();

    List<String> imagesParsed = imageStr.isNotEmpty ? [imageStr] : [];
    if (imageList != null && imageList.isNotEmpty) {
      imagesParsed = imageList.map((e) => e.toString()).toList();
      if (imageStr.isNotEmpty && !imagesParsed.contains(imageStr)) {
        imagesParsed = [imageStr, ...imagesParsed];
      }
    }

    List<Variant> variantsParsed = [];
    try {
      final vList = j['variants'] as List? ?? [];
      variantsParsed = vList
          .map((e) => Variant.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {}

    // Assembly: Homewares → No, else Yes (or from JSON)
    String assemblyRequired = (j['assemblyRequired'] as String? ?? '').trim();
    if (assemblyRequired.isEmpty) {
      final isHomeware = categoryList
          .any((c) => c.toLowerCase().contains('homeware'));
      assemblyRequired = isHomeware ? 'No' : 'Yes';
    }

    // Material: default Rubberwood for Children's Furniture if missing
    String? material = (j['material'] as String? ?? '').trim();
    if (material.isEmpty) material = null;
    final isChildren = categoryList
        .any((c) => c.toLowerCase().contains("children"));
    if (isChildren && material == null) material = 'Rubberwood';

    return Product(
      id: id,
      name: decodeHtmlEntities(j['name'] as String? ?? ''),
      price: price,
      regularPrice: regularPrice,
      salePrice: salePrice,
      onSale: onSale,
      currency: j['currency'] as String? ?? 'AUD',
      image: imageStr,
      images: imagesParsed,
      inStock: j['inStock'] as bool? ?? true,
      stockAmount: (j['stockAmount'] as String? ?? '').trim().isEmpty
          ? null
          : (j['stockAmount'] as String? ?? '').trim(),
      category: category,
      categoryList: categoryList,
      age: decodeHtmlEntities(j['age'] as String? ?? ''),
      description: decodeHtmlEntities(j['description'] as String? ?? ''),
      sku: skuResolved,
      variants: variantsParsed,
      material: material,
      assemblyRequired: assemblyRequired,
      color: (j['color'] as String? ?? '').trim().isEmpty
          ? null
          : (j['color'] as String? ?? '').trim(),
      weight: (j['weight'] as String? ?? '').trim().isEmpty
          ? null
          : (j['weight'] as String? ?? '').trim(),
      dimensions: (j['dimensions'] as String? ?? '').trim().isEmpty
          ? null
          : (j['dimensions'] as String? ?? '').trim(),
    );
  }

  /// First main category (Homewares, Children's Furniture, Outdoor Furniture) that appears in this product, or first category, or "Other".
  String get mainCategory {
    for (final main in kMainCategories) {
      if (categoryList
          .any((c) => c.toLowerCase().contains(main.toLowerCase()))) {
        return main;
      }
    }
    if (categoryList.isNotEmpty) return categoryList.first;
    final parts =
        category.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty);
    if (parts.isNotEmpty) return parts.first;
    return 'Other';
  }

  /// Main image only – used in list/grid. Sub images are in [images] for detail screen.
  String get primaryImage =>
      image.isNotEmpty ? image : (images.isNotEmpty ? images.first : "");
}
