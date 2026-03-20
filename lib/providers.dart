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
