import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'app_router.dart';
import 'config/store_cart_api_service.dart';
import 'features/cart/data/cart_providers.dart';
import 'features/cart/data/cart_remote_sync_binding.dart';
import 'features/checkout/data/checkout_providers.dart';
import 'services/product_sync_service.dart';
import 'services/product_image_cache_service.dart';
import 'services/web_auth_cookie_store.dart';
import 'services/web_session_cache.dart';
import 'services/order_history_sync_service.dart';
import 'services/cart_sync_service.dart';
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
  await WebAuthCookieStore.init();
  await WebSessionCache.init();

  await OrderHistorySyncService.instance.init();
  await CartSyncService.instance.init();

  // Initialise auth (restores persisted JWT session if present).
  await AuthService.instance.init();

  // Single-writer cart engine. Started after auth so it resolves the right
  // user key, and after CartSyncService.init so the cache directory exists.
  await initCartCoordinator();

  // Settle any order that was submitted but never confirmed — the app being
  // killed mid-POST is exactly the case this exists for. Not awaited: startup
  // must never block on the network, and until it resolves the cart is simply
  // left intact, which is the safe state.
  reconcileCheckoutAttempt().ignore();

  await ProductImageCacheService.instance.init();

  // Phased sync only makes sense once we have a session (hard lock). The splash
  // screen validates/refreshes the token, then kicks off the catalogue sync.
  if (AuthService.instance.isSignedIn) {
    ProductSyncService.instance.ensureCatalogLoaded().ignore();
  }

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
