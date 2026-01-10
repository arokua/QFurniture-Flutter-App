import 'package:flutter/widgets.dart';

class Product {
  final int id;
  final String sku;
  final String name;
  final List<String> categories;
  final List<String> images;
  final String regularPrice;
  final String salePrice;
  final String shortDescription;
  final String longDescription;
  final String? material;
  final String? age;
  final Map<String, dynamic>? dimensions;
  final String? weight;
  final bool assemblyRequired;

  const Product({
    required this.id,
    required this.sku,
    required this.name,
    required this.categories,
    required this.images,
    required this.regularPrice,
    required this.salePrice,
    required this.shortDescription,
    required this.longDescription,
    required this.material,
    required this.age,
    required this.dimensions,
    required this.weight,
    required this.assemblyRequired,
  });

  factory Product.placeholder(
    String image,
    String name,
    String description,
    double price,
  ) {
    return Product(
      id: -1,
      sku: '',
      name: name,
      categories: const [],
      images: [image],
      regularPrice: price.toString(),
      salePrice: '',
      shortDescription: description,
      longDescription: description,
      material: null,
      age: null,
      dimensions: null,
      weight: null,
      assemblyRequired: true,
    );
  }

  factory Product.fromApiJson(Map<String, dynamic> json) {
    final prices = json['prices'] as Map<String, dynamic>?;
    final categoryNames = _extractNames(json['categories']);
    return Product(
      id: json['id'] as int? ?? 0,
      sku: json['sku']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      categories: categoryNames,
      images: _extractImageUrls(json['images']),
      regularPrice: prices?['regular_price']?.toString() ?? '',
      salePrice: prices?['sale_price']?.toString() ?? '',
      shortDescription: json['short_description']?.toString() ?? '',
      longDescription: json['description']?.toString() ?? '',
      material: _extractAttributeValue(json, 'pa_material',
          nameFallbacks: const ['material']),
      age: _extractAttributeValue(json, 'pa_age', nameFallbacks: const ['age']),
      dimensions: json['dimensions'] as Map<String, dynamic>?,
      weight: json['weight']?.toString(),
      assemblyRequired: !_hasHomewaresCategory(categoryNames),
    );
  }

  String get description =>
      shortDescription.isNotEmpty ? shortDescription : longDescription;

  double get price => _parsePrice(salePrice.isNotEmpty ? salePrice : regularPrice);

  String get image => images.isNotEmpty ? images.first : _fallbackImage;

  bool get hasNetworkImage => image.startsWith('http');

  ImageProvider<Object> get imageProvider {
    if (hasNetworkImage) {
      return NetworkImage(image);
    }
    return AssetImage(image);
  }

  static const String _fallbackImage = 'assets/headphones.png';

  static double _parsePrice(String? value) {
    if (value == null || value.isEmpty) {
      return 0;
    }
    return double.tryParse(value) ?? 0;
  }

  static List<String> _extractNames(dynamic rawList) {
    if (rawList is! List) {
      return const [];
    }
    return rawList
        .map((entry) {
          if (entry is Map<String, dynamic>) {
            return entry['name']?.toString();
          }
          return entry?.toString();
        })
        .whereType<String>()
        .toList();
  }

  static List<String> _extractImageUrls(dynamic rawList) {
    if (rawList is! List) {
      return const [];
    }
    return rawList
        .map((entry) {
          if (entry is Map<String, dynamic>) {
            return entry['src']?.toString();
          }
          return entry?.toString();
        })
        .whereType<String>()
        .toList();
  }

  static bool _hasHomewaresCategory(List<String> categories) {
    return categories.any((name) => name.toLowerCase() == 'homewares');
  }

  static String? _extractAttributeValue(
    Map<String, dynamic> json,
    String slug, {
    List<String> nameFallbacks = const [],
  }) {
    final attributes = json['attributes'];
    if (attributes is! List) {
      return null;
    }
    for (final attr in attributes) {
      if (attr is! Map<String, dynamic>) {
        continue;
      }
      final attrSlug = attr['slug']?.toString();
      final attrName = attr['name']?.toString().toLowerCase();
      final matches = attrSlug == slug ||
          (attrName != null && nameFallbacks.contains(attrName));
      if (!matches) {
        continue;
      }
      final terms = attr['terms'] ?? attr['options'];
      if (terms is List) {
        final values = terms
            .map((term) {
              if (term is Map<String, dynamic>) {
                return term['name']?.toString() ?? term['value']?.toString();
              }
              return term?.toString();
            })
            .whereType<String>()
            .toList();
        if (values.isNotEmpty) {
          return values.join(', ');
        }
      } else if (terms != null) {
        return terms.toString();
      }
    }
    return null;
  }
}
