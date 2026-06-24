import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/category_repository.dart';
import '../domain/category.dart';
import '../domain/category_filter.dart';

final categoryRepositoryProvider = Provider((ref) => CategoryRepository());

final categoryTreeProvider = FutureProvider<List<Category>>((ref) async {
  return ref.watch(categoryRepositoryProvider).getCategoryTree();
});

final categoryFilterIndexProvider = FutureProvider<CategoryFilterIndex>((ref) async {
  final flat = await ref.watch(categoryRepositoryProvider).fetchCategories();
  return CategoryFilterIndex.fromFlat(flat);
});

/// Active category filter (includes id for descendant-aware matching).
final selectedCategoryProvider = StateProvider<SelectedCategory?>((ref) => null);
