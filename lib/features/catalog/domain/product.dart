import '../utils/html_utils.dart';
import 'product_pricing_policy.dart';
import 'role_pricing.dart';

/// Products with this many units or fewer (but > 0) show the low-stock badge.
const int kLowStockThreshold = 5;

/// Currency exponent declared by the payload, defaulting to 2 (cents).
///
/// The WooCommerce Store API states this explicitly, and the on-device product
/// cache stores raw API shape, so both carry it. The bundled catalogue
/// (`assets/data/products.json`) predates the field and holds raw minor units,
/// which is why 2 is the right default.
int resolveCurrencyMinorUnit(Map<String, dynamic> j) {
  final raw = j['currency_minor_unit'] ??
      (j['prices'] as Map<String, dynamic>?)?['currency_minor_unit'];
  if (raw is int) return raw;
  return int.tryParse(raw?.toString() ?? '') ?? 2;
}

/// Converts a Store API price value to a major-unit amount.
///
/// Store API amounts are integers in minor units: `"990"` with
/// `currency_minor_unit: 2` means **$9.90**. A value carrying a decimal point
/// is already a major-unit amount and is passed through.
///
/// This replaces a magnitude heuristic (`>= 1000 && whole ⇒ cents` for
/// products, `>= 100` for variants) that rendered every item under $10.00 at
/// 100x its price and made a product disagree with its own variants.
double parseMinorUnitPrice(dynamic v, int minorUnit) {
  if (v == null) return 0.0;

  var divisor = 1.0;
  for (var i = 0; i < minorUnit; i++) {
    divisor *= 10;
  }

  if (v is num) {
    final d = v.toDouble();
    // Minor-unit amounts are always whole; a fraction means major units.
    if (d != d.truncateToDouble()) return d;
    return d / divisor;
  }
  if (v is String) {
    final s = v.trim();
    if (s.isEmpty) return 0.0;
    if (s.contains('.')) {
      return double.tryParse(s.replaceAll(RegExp(r'[^\d.]'), '')) ?? 0.0;
    }
    final d = double.tryParse(s.replaceAll(RegExp(r'[^\d]'), ''));
    if (d == null) return 0.0;
    return d / divisor;
  }
  return 0.0;
}

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

  double priceForRole(String? role) =>
      RolePricing.roundMoney(price * RolePricing.multiplierFor(role));

  factory Variant.fromJson(Map<String, dynamic> j) {
    // Variations in Store API also use a 'prices' object.
    final pObj = j['prices'] as Map<String, dynamic>?;
    final minorUnit = resolveCurrencyMinorUnit(j);
    return Variant(
      sku: (j['sku'] ?? '').toString(),
      label: (j['label'] ?? j['name'] ?? '').toString(),
      price: parseMinorUnitPrice(
        j['price'] ??
            pObj?['price'] ??
            j['regular_price'] ??
            pObj?['regular_price'],
        minorUnit,
      ),
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
  final String? permalink; // Product permalink from WC Store API
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
  final String? finish; // pa_finish (e.g. sealant)
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
    this.permalink,
    required this.inStock,
    this.stockAmount,
    required this.category,
    required this.categoryList,
    required this.age,
    required this.description,
    this.sku,
    required this.variants,
    this.material,
    this.finish,
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
    // See [parseMinorUnitPrice]: Store API amounts are integers in minor units.
    final minorUnit = resolveCurrencyMinorUnit(j);
    double parsePriceField(dynamic v) => parseMinorUnitPrice(v, minorUnit);

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
    String? apiFinish;
    String? apiAgeTerms;
    final attrs = j['attributes'] as List?;
    if (attrs != null) {
      for (final a in attrs) {
        if (a is Map) {
          final taxonomy = (a['taxonomy'] ?? a['slug'] ?? '')
              .toString()
              .toLowerCase();
          final terms = a['terms'] as List?;
          final firstTerm = (terms != null && terms.isNotEmpty) ? terms.first : null;
          final value = (firstTerm is Map) ? firstTerm['name']?.toString() : null;

          if (taxonomy == 'pa_material') apiMaterial = value;
          if (taxonomy == 'pa_color') apiColor = value;
          if (taxonomy == 'pa_assembly_required') apiAssembly = value;
          if (taxonomy == 'pa_finish') apiFinish = value;
          if (taxonomy == 'pa_age') apiAgeTerms = value;
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

    // WC Store API often includes a `permalink` field; use it so UI opens
    // the correct product page instead of relying on `?p=ID`.
    final String? permalinkVal =
        (j['permalink'] ?? j['link'] ?? j['url'])?.toString();
    final String? permalink = permalinkVal?.trim().isNotEmpty == true
        ? decodeHtmlEntities(permalinkVal!)
        : null;

    final built = Product(
      id: id,
      name: decodeHtmlEntities(j['name'] as String? ?? ''),
      price: price,
      regularPrice: regularPrice,
      salePrice: salePrice,
      onSale: onSale,
      currency: currency,
      image: imageStr,
      images: imagesParsed,
      permalink: permalink,
      inStock: j['inStock'] ?? apiInStock,
      stockAmount: stockNormalized,
      category: category,
      categoryList: categoryList,
      age: () {
        final fromJson =
            decodeHtmlEntities(j['age'] as String? ?? '').trim();
        if (fromJson.isNotEmpty) return fromJson;
        if (apiAgeTerms != null && apiAgeTerms.trim().isNotEmpty) {
          return decodeHtmlEntities(apiAgeTerms.trim());
        }
        return '';
      }(),
      description: decodeHtmlEntities(j['description'] as String? ?? j['short_description'] as String? ?? ''),
      sku: skuResolved,
      variants: variantsParsed,
      material: material,
      finish: (apiFinish ?? '').trim().isEmpty
          ? null
          : decodeHtmlEntities(apiFinish!.trim()),
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
    return _applyBackupPricingIfApplicable(built);
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

  /// Remote URL, bundled asset path, or empty for [imageIndex] (gallery order).
  String imageSourceAt(int index) {
    if (images.isNotEmpty && index < images.length) {
      return images[index];
    }
    if (index == 0) {
      if (image.isNotEmpty) return image;
      return primaryImage;
    }
    return '';
  }

  int get imageCount => images.isNotEmpty ? images.length : (primaryImage.isNotEmpty ? 1 : 0);

  int? get parsedStockQuantityApprox {
    if (!inStock) return 0;
    final s = stockAmount?.trim();
    if (s == null || s.isEmpty) return null;
    final m = RegExp(r'\d+').firstMatch(s);
    if (m == null) return null;
    return int.tryParse(m.group(0)!);
  }

  /// In stock with a known small quantity, or stock text mentions low stock.
  bool get isLowStock {
    if (!inStock) return false;
    final qty = parsedStockQuantityApprox;
    if (qty != null) {
      return qty > 0 && qty <= kLowStockThreshold;
    }
    final lower = stockAmount?.toLowerCase() ?? '';
    return lower.contains('low stock') || lower.contains('only');
  }

  /// Sort key: higher = more stock. Out-of-stock sorts last.
  int get stockSortKey {
    if (!inStock) return -1;
    return parsedStockQuantityApprox ?? 999999;
  }

  /// Retailer reference from WooCommerce; scaled by [RolePricing] for the session role.
  double displayCurrentPriceForRole(String? role) {
    final m = RolePricing.multiplierFor(role);
    if (onSale && salePrice != null) {
      return RolePricing.roundMoney(salePrice! * m);
    }
    return RolePricing.roundMoney(price * m);
  }

  double? displayRegularPriceForRole(String? role) {
    if (regularPrice == null) return null;
    return RolePricing.roundMoney(regularPrice! * RolePricing.multiplierFor(role));
  }

  double? displaySalePriceForRole(String? role) {
    if (!onSale || salePrice == null) return null;
    return RolePricing.roundMoney(salePrice! * RolePricing.multiplierFor(role));
  }
}

/// Web store backup list price + 10% off sale for known `P00x` furniture SKUs.
Product _applyBackupPricingIfApplicable(Product p) {
  final reg = backupRegularPriceForSku(p.sku);
  if (reg == null) return p;
  final sale = RolePricing.roundMoney(reg * 0.9);
  return Product(
    id: p.id,
    name: p.name,
    price: sale,
    regularPrice: reg,
    salePrice: sale,
    onSale: true,
    currency: p.currency,
    image: p.image,
    images: p.images,
    permalink: p.permalink,
    inStock: p.inStock,
    stockAmount: p.stockAmount,
    category: p.category,
    categoryList: p.categoryList,
    age: p.age,
    description: p.description,
    sku: p.sku,
    variants: p.variants,
    material: p.material,
    finish: p.finish,
    assemblyRequired: p.assemblyRequired,
    color: p.color,
    weight: p.weight,
    dimensions: p.dimensions,
  );
}
