import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'features/cart/presentation/cart_screen.dart';
import 'features/catalog/presentation/favorites_screen.dart';
import 'features/catalog/presentation/product_detail_screen.dart';
import 'features/catalog/presentation/store_webview_screen.dart';
import 'features/auth/presentation/login_screen.dart';
import 'features/auth/presentation/registration_screen.dart';
import 'features/orders/presentation/order_history_screen.dart';
import 'screens/main_tab_screen.dart';
import 'screens/splash_screen.dart';
import 'services/auth_service.dart';
import 'config/store_config.dart';

/// All app route paths. Use these for context.push(path) / context.go(path).
abstract class AppRoutes {
  static const String root = '/';
  static const String login = '/login';
  static const String register = '/register';
  static const String home = '/home';
  static const String homeCategories = '/home/categories';
  static const String homeMore = '/home/more';
  static const String cart = '/cart';
  static const String favorites = '/favorites';
  static const String orders = '/orders';
  static const String store = '/store';
  static String product(int id) => '/p/$id';
}

final router = GoRouter(
  initialLocation: AppRoutes.root,
  debugLogDiagnostics: true,
  refreshListenable: AuthService.instance,
  redirect: (ctx, state) {
    final signedIn = AuthService.instance.isSignedIn;
    final path = state.uri.path;

    // Splash decides where to go (it also validates/refreshes the token).
    if (path == AppRoutes.root) return null;

    final isPublicAuth =
        path == AppRoutes.login || path == AppRoutes.register;

    // Hard lock: nothing in the app is reachable until the user is signed in.
    if (!signedIn) {
      return isPublicAuth ? null : AppRoutes.login;
    }

    // Signed in: keep users out of the auth screens.
    if (isPublicAuth) return AppRoutes.home;
    return null;
  },
  routes: [
    GoRoute(
      path: AppRoutes.root,
      builder: (_, __) => const SplashScreen(),
    ),
    GoRoute(
      path: AppRoutes.login,
      builder: (_, __) => const LoginScreen(),
    ),
    GoRoute(
      path: AppRoutes.register,
      builder: (_, __) => const RegistrationScreen(),
    ),
    GoRoute(
      path: AppRoutes.home,
      builder: (_, __) => const MainTabScreen(initialIndex: 0),
    ),
    GoRoute(
      path: AppRoutes.homeCategories,
      builder: (_, __) => const MainTabScreen(initialIndex: 1),
    ),
    GoRoute(
      path: AppRoutes.homeMore,
      builder: (_, __) => const MainTabScreen(initialIndex: 2),
    ),
    GoRoute(
      path: AppRoutes.cart,
      name: 'cart',
      builder: (_, __) => const CartScreen(),
    ),
    GoRoute(
      path: AppRoutes.favorites,
      name: 'favorites',
      builder: (_, __) => const FavoritesScreen(),
    ),
    GoRoute(
      path: AppRoutes.orders,
      name: 'orders',
      builder: (_, __) => const OrderHistoryScreen(),
    ),
    GoRoute(
      path: '/p/:id',
      builder: (ctx, st) {
        final id = int.parse(st.pathParameters['id']!);
        return ProductDetailScreen(productId: id);
      },
    ),
    GoRoute(
      path: AppRoutes.store,
      builder: (ctx, st) {
        final url = st.uri.queryParameters['url'] ?? storeCartUrl;
        final autoLogin = st.uri.queryParameters['autologin'] == '1';
        final mobileLayout = st.uri.queryParameters['mobile'] == '1';
        final extra = st.extra;
        List<({int productId, int quantity})>? addToCartItems;
        if (extra is List) {
          addToCartItems = extra
              .map((e) => e is Map
                  ? (
                      productId: (e['productId'] as num).toInt(),
                      quantity: (e['quantity'] as num).toInt(),
                    )
                  : null)
              .whereType<({int productId, int quantity})>()
              .toList();
        }
        return StoreWebViewScreen(
          initialUrl: url,
          attemptWebLogin: autoLogin,
          addToCartItems: addToCartItems,
          useMobileLayout: mobileLayout,
        );
      },
    ),
  ],
  errorBuilder: (context, state) => Scaffold(
    appBar: AppBar(title: const Text('Page not found')),
    body: Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('No route for: ${state.uri.path}'),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => context.go(AppRoutes.home),
            child: const Text('Go to home'),
          ),
        ],
      ),
    ),
  ),
);
