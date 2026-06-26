import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'features/catalog/data/product_local_datasource.dart';
import 'features/catalog/data/product_remote_datasource.dart';
import 'features/catalog/data/product_repository.dart';

/// Shared top-level providers used across multiple screens.
/// Keeping these separate from main.dart breaks the circular import chain
/// that previously existed: main.dart → app_router.dart → screens → main.dart
final productRepoProvider = Provider<ProductRepository>(
  (ref) => ProductRepository(ProductLocalDataSource(), ProductRemoteDataSource()),
);

/// Product id → SKU from the on-device catalogue (for cart lines when the API omits SKU).
final catalogSkuByProductIdProvider =
    FutureProvider<Map<int, String>>((ref) async {
  final products = await ref.watch(productRepoProvider).getAll();
  return {
    for (final p in products)
      p.id: (p.sku != null && p.sku!.trim().isNotEmpty)
          ? p.sku!.trim()
          : '${p.id}',
  };
});
