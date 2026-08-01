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
  static const String homeNewArrivals = '/home/new-arrivals';
  static const String homeCategories = '/home/categories';
  static const String homeMore = '/home/more';
  static const String cart = '/cart';
  static const String favorites = '/favorites';
  static const String orders = '/orders';
  static const String store = '/store';
  static String product(int id) => '/p/$id';
}

/// Routes a signed-out visitor may browse.
///
/// Browsing and building a basket are deliberately open: the cart engine is
/// local-first, so a guest basket costs no network at all and is merged into
/// the account by `CartCoordinator.adoptCart` on sign-in. Only the routes that
/// genuinely need an identity are gated.
const Set<String> _guestRoutes = {
  AppRoutes.login,
  AppRoutes.register,
  AppRoutes.home,
  AppRoutes.homeNewArrivals,
  AppRoutes.homeCategories,
  AppRoutes.homeMore,
  AppRoutes.cart,
  AppRoutes.favorites,
};

bool _isGuestRoute(String path) =>
    _guestRoutes.contains(path) || path.startsWith('/p/');

final rootNavigatorKey = GlobalKey<NavigatorState>();

final router = GoRouter(
  navigatorKey: rootNavigatorKey,
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

    if (!signedIn) {
      if (_isGuestRoute(path)) return null;
      // Carry the intended destination so signing in lands the user where they
      // were going instead of dumping them on the home tab.
      return Uri(
        path: AppRoutes.login,
        queryParameters: <String, String>{'from': path},
      ).toString();
    }

    // Signed in: keep users out of the auth screens.
    if (isPublicAuth) {
      final from = state.uri.queryParameters['from'];
      // A `from` pointing back at an auth screen would bounce forever.
      if (from == null || from.isEmpty || from == AppRoutes.login ||
          from == AppRoutes.register) {
        return AppRoutes.home;
      }
      return from;
    }
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
      path: AppRoutes.homeNewArrivals,
      builder: (_, __) => const MainTabScreen(initialIndex: 1),
    ),
    GoRoute(
      path: AppRoutes.homeCategories,
      builder: (_, __) => const MainTabScreen(initialIndex: 2),
    ),
    GoRoute(
      path: AppRoutes.homeMore,
      builder: (_, __) => const MainTabScreen(initialIndex: 3),
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
