import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app_router.dart';
import '../domain/category.dart';
import '../domain/category_filter.dart';
import '../providers/category_providers.dart';

/// Apply a category filter and open the main catalogue tab.
void openCatalogWithCategory(
  WidgetRef ref,
  BuildContext context, {
  required String categoryName,
  Category? category,
}) {
  SelectedCategory? selected;
  if (category != null) {
    selected = SelectedCategory(id: category.id, name: category.name);
  } else {
    final index = ref.read(categoryFilterIndexProvider).valueOrNull;
    selected = index?.resolveByName(categoryName) ??
        SelectedCategory(id: 0, name: categoryName);
  }
  ref.read(selectedCategoryProvider.notifier).state = selected;
  context.go(AppRoutes.home);
}
