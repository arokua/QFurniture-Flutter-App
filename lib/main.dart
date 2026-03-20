import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'app_router.dart';
import 'config/store_cart_api_service.dart';
import 'services/product_sync_service.dart';
import 'services/auth_service.dart';

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
      title: 'qtoys',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF8BC34A), // light green brand
        fontFamily: 'Roboto',
      ),
      routerConfig: router,
    );
  }
}
