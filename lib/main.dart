import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app_router.dart';
import 'features/catalog/data/product_remote_datasource.dart';
import 'features/catalog/data/product_local_datasource.dart';
import 'features/catalog/data/product_repository.dart';
import 'config/store_cart_api_service.dart';

final productRepoProvider = Provider<ProductRepository>(
  (ref) => ProductRepository(ProductLocalDataSource(), ProductRemoteDataSource()),
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await StoreCartApiService.instance.init();
  runApp(const ProviderScope(child: AppRoot()));
}

class AppRoot extends StatelessWidget {
  const AppRoot({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'QFurniture',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF795548), // Brown
      ),
      routerConfig: router,
    );
  }
}
