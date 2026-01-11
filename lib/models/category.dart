import 'package:flutter/material.dart';

class Category {
  final int id;
  final String name;
  final String slug;
  final String? description;
  final String? image;
  final int count; // Number of products in this category
  final int? parent; // Parent category ID for subcategories
  
  // Legacy UI properties (for backward compatibility with old UI components)
  final Color? begin; // Gradient start color
  final Color? end; // Gradient end color
  final String? category; // Legacy category name (use 'name' instead)

  const Category({
    required this.id,
    required this.name,
    required this.slug,
    this.description,
    this.image,
    required this.count,
    this.parent,
    // Legacy properties
    this.begin,
    this.end,
    this.category,
  });
  
  // Legacy constructor for old UI components (backward compatibility)
  Category.legacy(
    Color beginColor,
    Color endColor,
    String categoryName,
    String imagePath,
  ) : this(
          id: 0,
          name: categoryName,
          slug: categoryName.toLowerCase().replaceAll(' ', '-'),
          image: imagePath,
          count: 0,
          begin: beginColor,
          end: endColor,
          category: categoryName,
        );

  factory Category.fromJson(Map<String, dynamic> json) {
    return Category(
      id: json['id'] as int? ?? 0,
      name: json['name']?.toString() ?? '',
      slug: json['slug']?.toString() ?? '',
      description: json['description']?.toString(),
      image: _extractImageUrl(json['image']),
      count: json['count'] as int? ?? 0,
      parent: json['parent'] as int?,
    );
  }

  static String? _extractImageUrl(dynamic imageData) {
    if (imageData is Map<String, dynamic>) {
      return imageData['src']?.toString();
    }
    return null;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'slug': slug,
      'description': description,
      'image': image,
      'count': count,
      'parent': parent,
    };
  }
}
