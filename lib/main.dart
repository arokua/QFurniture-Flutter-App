import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'app_router.dart';
import 'config/store_cart_api_service.dart';
import 'features/cart/data/cart_remote_sync_binding.dart';
import 'services/product_sync_service.dart';
import 'services/auth_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Enable edge-to-edge on Android so the system navigation bar doesn't
  // clip the bottom of the app content (the 20px overflow bug).
  // SafeArea / MediaQuery.padding still handle insets correctly inside the app.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  await dotenv.load(fileName: '.env');

  // Initialise cart session (cookie-based WooCommerce cart)
  await StoreCartApiService.instance.init();

  // Initialise auth (Supabase / local fallback)
  await AuthService.instance.init();

  // Phased sync: latest products first, full catalogue in background when signed in.
  ProductSyncService.instance.ensureCatalogLoaded().ignore();

  runApp(const ProviderScope(
    child: CartRemoteSyncBinding(child: AppRoot()),
  ));
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
