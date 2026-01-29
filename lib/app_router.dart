import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'features/cart/presentation/cart_screen.dart';
import 'features/catalog/presentation/favorites_screen.dart';
import 'features/catalog/presentation/product_detail_screen.dart';
import 'screens/main_tab_screen.dart';
import 'screens/splash_screen.dart';

/// All app route paths. Use these for context.push(path) / context.go(path).
abstract class AppRoutes {
  static const String root = '/';
  static const String home = '/home';
  static const String homeCategories = '/home/categories';
  static const String homeMore = '/home/more';
  static const String cart = '/cart';
  static const String favorites = '/favorites';
  static String product(int id) => '/p/$id';
}

final router = GoRouter(
  initialLocation: AppRoutes.root,
  debugLogDiagnostics: true,
  routes: [
    GoRoute(
      path: AppRoutes.root,
      builder: (_, __) => const SplashScreen(),
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
      path: '/p/:id',
      builder: (ctx, st) {
        final id = int.parse(st.pathParameters['id']!);
        return ProductDetailScreen(productId: id);
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
