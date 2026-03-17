import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app_router.dart';
import 'features/catalog/data/product_remote_datasource.dart';
import 'features/catalog/data/product_local_datasource.dart';
import 'features/catalog/data/product_repository.dart';
import 'config/store_cart_api_service.dart';
import 'services/product_sync_service.dart';
import 'services/auth_service.dart';

final productRepoProvider = Provider<ProductRepository>(
  (ref) => ProductRepository(ProductLocalDataSource(), ProductRemoteDataSource()),
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialise cart session (cookie-based WooCommerce cart)
  await StoreCartApiService.instance.init();

  // Initialise auth (Supabase / local fallback)
  await AuthService.instance.init();

  // Pre-warm the product sync cache so the first load is fast.
  // This runs async – the UI won't wait for it; products will appear once ready.
  ProductSyncService.instance.getProducts().ignore();

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
        colorSchemeSeed: const Color(0xFF795548), // brand brown
        fontFamily: 'Roboto',
      ),
      routerConfig: router,
    );
  }
}
