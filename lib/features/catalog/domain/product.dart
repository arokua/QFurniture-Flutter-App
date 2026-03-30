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

  factory Variant.fromJson(Map<String, dynamic> j) {
    // Variations in Store API also use a 'prices' object
    final pObj = j['prices'] as Map<String, dynamic>?;
    
    double parsePrice(dynamic v) {
      if (v == null) return 0.0;
      double d = 0.0;
      if (v is num) {
        d = v.toDouble();
        if (d >= 100 && d == d.truncateToDouble()) return d / 100;
        return d;
      }
      if (v is String) {
        d = double.tryParse(v.replaceAll(RegExp(r'[^\d.]'), '')) ?? 0.0;
        if (d >= 100 && (!v.contains('.') || v.endsWith('.0') || v.endsWith('.00'))) {
          return d / 100;
        }
        return d;
      }
      return 0.0;
    }
    return Variant(
      sku: (j['sku'] ?? '').toString(),
      label: (j['label'] ?? j['name'] ?? '').toString(),
      price: parsePrice(j['price'] ?? pObj?['price'] ?? j['regular_price'] ?? pObj?['regular_price']),
      inStock: j['inStock'] ?? j['in_stock'] ?? (j['is_in_stock'] ?? true),
    );
  }
}

/// Main catalogue categories used for filtering (same as elsewhere in the app).
const List<String> kMainCategories = [
  'Toys and Educational Resources',
  'Furniture and Preschool Equipment',
  'Homewares',
  'New Arrivals',
  'By Age Group',
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
    double parsePriceField(dynamic v) {
      if (v == null) return 0.0;
      double? d;
      if (v is num) {
        d = v.toDouble();
        // Only divide by 100 when value looks like cents (integer >= 100). Already-in-dollars (e.g. from sync) must not be divided again.
        if (d >= 100 && d == d.truncateToDouble()) return d / 100;
        return d;
      }
      if (v is String) {
        d = double.tryParse(v.replaceAll(RegExp(r'[^\d.]'), ''));
        if (d == null) return 0.0;
        // If string looks like a large raw number (no dot or .00) it's likely cents
        if (d >= 100 && (!v.contains('.') || v.endsWith('.0') || v.endsWith('.00'))) {
          return d / 100;
        }
        return d;
      }
      return 0.0;
    }

    // Price logic handles local JSON (root keys) and WC Store API (nested 'prices' object)
    final pricesObj = j['prices'] as Map<String, dynamic>?;
    
    final rawPrice = j['price'] ?? 
                     pricesObj?['price'] ?? 
                     j['regularPrice'] ?? 
                     pricesObj?['regular_price'] ?? 
                     j['salePrice'] ?? 
                     pricesObj?['sale_price'] ??
                     j['regular_price'] ??
                     j['sale_price'];
                     
    final double price = parsePriceField(rawPrice);
    
    final rawReg = j['regularPrice'] ?? pricesObj?['regular_price'] ?? j['regular_price'];
    final double? regularPrice = rawReg != null ? parsePriceField(rawReg) : null;
    
    final rawSale = j['salePrice'] ?? pricesObj?['sale_price'] ?? j['sale_price'];
    final double? salePrice = rawSale != null ? parsePriceField(rawSale) : null;
    
    final bool onSale = j['onSale'] ?? j['on_sale'] ?? (salePrice != null && regularPrice != null && salePrice < regularPrice);
    final String currency = j['currency'] as String? ?? pricesObj?['currency_code'] as String? ?? 'AUD';

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

    // Attributes from WooCommerce Store API (pa_material, pa_color, etc.)
    String? apiMaterial;
    String? apiColor;
    String? apiAssembly;
    final attrs = j['attributes'] as List?;
    if (attrs != null) {
      for (final a in attrs) {
        if (a is Map) {
          final slug = a['slug']?.toString().toLowerCase() ?? '';
          final terms = a['terms'] as List?;
          final firstTerm = (terms != null && terms.isNotEmpty) ? terms.first : null;
          final value = (firstTerm is Map) ? firstTerm['name']?.toString() : null;
          
          if (slug == 'pa_material') apiMaterial = value;
          if (slug == 'pa_color') apiColor = value;
          if (slug == 'pa_assembly_required') apiAssembly = value;
        }
      }
    }

    // Handle WooCommerce API standard format where image is { id: ..., src: "https://..." }
    String mainImageStr = '';
    final jImage = j['image'] ?? j['images']?.first; // Sometimes main image is just in images array
    if (jImage is String) {
      mainImageStr = jImage;
    } else if (jImage is Map && jImage['src'] != null) {
      mainImageStr = jImage['src'].toString();
    }

    List<String> imagesParsed = mainImageStr.isNotEmpty ? [mainImageStr] : [];
    if (imageList != null && imageList.isNotEmpty) {
      imagesParsed = [];
      for (final e in imageList) {
        if (e is String) {
          imagesParsed.add(e);
        } else if (e is Map && e['src'] != null) {
          imagesParsed.add(e['src'].toString());
        }
      }
      if (mainImageStr.isNotEmpty && !imagesParsed.contains(mainImageStr)) {
        imagesParsed = [mainImageStr, ...imagesParsed];
      }
    }

    List<Variant> variantsParsed = [];
    try {
      final vList = j['variants'] as List? ?? [];
      variantsParsed = vList
          .map((e) => Variant.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {}

    // Assembly: Homewares → No, else Yes (or from JSON or API attribute)
    String assemblyRequired = (j['assemblyRequired'] as String? ?? apiAssembly ?? '').trim();
    if (assemblyRequired.isEmpty) {
      final isHomeware = categoryList
          .any((c) => c.toLowerCase().contains('homeware'));
      assemblyRequired = isHomeware ? 'No' : 'Yes';
    }

    // Material: default Rubberwood for Children's Furniture if missing
    String? material = (j['material'] as String? ?? apiMaterial ?? '').trim();
    if (material.isEmpty) material = null;
    final isChildren = categoryList
        .any((c) => c.toLowerCase().contains("children"));
    if (isChildren && material == null) material = 'Rubberwood';

    // Stock mapping for Store API (may include HTML in stockAmount from WC)
    final bool apiInStock = j['is_in_stock'] ?? (j['stock_status'] == 'instock');
    final apiStockAmount = j['stock_quantity']?.toString();
    final String? rawStock = (j['stockAmount'] as String? ?? '').trim().isNotEmpty
        ? (j['stockAmount'] as String? ?? '').trim()
        : (apiStockAmount != null ? '$apiStockAmount in stock' : null);
    final String? stockNormalized = normalizeStockDisplay(rawStock);

    return Product(
      id: id,
      name: decodeHtmlEntities(j['name'] as String? ?? ''),
      price: price,
      regularPrice: regularPrice,
      salePrice: salePrice,
      onSale: onSale,
      currency: currency,
      image: imageStr,
      images: imagesParsed,
      inStock: j['inStock'] ?? apiInStock,
      stockAmount: stockNormalized,
      category: category,
      categoryList: categoryList,
      age: decodeHtmlEntities(j['age'] as String? ?? ''),
      description: decodeHtmlEntities(j['description'] as String? ?? j['short_description'] as String? ?? ''),
      sku: skuResolved,
      variants: variantsParsed,
      material: material,
      assemblyRequired: assemblyRequired,
      color: (j['color'] as String? ?? apiColor ?? '').trim().isEmpty
          ? null
          : (j['color'] as String? ?? apiColor ?? '').trim(),
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
