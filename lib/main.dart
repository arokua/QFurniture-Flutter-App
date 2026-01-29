import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app_router.dart';
import 'features/catalog/data/product_local_datasource.dart';
import 'features/catalog/data/product_repository.dart';

final productRepoProvider = Provider<ProductRepository>(
  (ref) => ProductRepository(ProductLocalDataSource()),
);

void main() {
  runApp(const ProviderScope(child: AppRoot()));
}

class AppRoot extends StatelessWidget {
  const AppRoot({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'QFurniture',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF4CAF50)),
      routerConfig: router,
    );
  }
}
