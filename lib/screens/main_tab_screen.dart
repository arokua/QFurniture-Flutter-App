import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../app_router.dart';
import '../features/catalog/presentation/product_list_screen.dart';
import '../services/auth_service.dart';
import 'categories_screen.dart';
import 'more_screen.dart';

/// Main shell with bottom tabs: Catalog, New Arrivals, Categories, Profile.
class MainTabScreen extends ConsumerStatefulWidget {
  const MainTabScreen({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  ConsumerState<MainTabScreen> createState() => _MainTabScreenState();
}

class _MainTabScreenState extends ConsumerState<MainTabScreen> {
  late int _currentIndex;

  static const List<_TabItem> _tabs = [
    _TabItem(label: 'Catalog', icon: Icons.grid_view, route: AppRoutes.home),
    _TabItem(
      label: 'New',
      icon: Icons.local_fire_department,
      route: AppRoutes.homeNewArrivals,
      accentColor: Color(0xFFFF6D00),
    ),
    _TabItem(
      label: 'Categories',
      icon: Icons.view_week_outlined,
      route: AppRoutes.homeCategories,
    ),
    _TabItem(
      label: 'Profile',
      icon: Icons.account_circle_outlined,
      route: AppRoutes.homeMore,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, _tabs.length - 1);
  }

  @override
  void didUpdateWidget(MainTabScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialIndex != widget.initialIndex) {
      _currentIndex = widget.initialIndex.clamp(0, _tabs.length - 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: const [
          ProductListScreen(),
          ProductListScreen(newArrivalsOnly: true),
          CategoriesScreen(),
          MoreScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          // Catalog + New Arrivals are browseable without sign-in.
          if (index > 1 && !AuthService.instance.isSignedIn) {
            context.push(AppRoutes.login);
            return;
          }
          setState(() => _currentIndex = index);
          context.go(_tabs[index].route);
        },
        destinations: _tabs.map((t) {
          final accent = t.accentColor;
          return NavigationDestination(
            icon: Icon(
              t.icon,
              color: accent,
            ),
            selectedIcon: Icon(
              t.icon,
              color: accent ?? Theme.of(context).colorScheme.primary,
            ),
            label: t.label,
          );
        }).toList(),
      ),
    );
  }
}

class _TabItem {
  const _TabItem({
    required this.label,
    required this.icon,
    required this.route,
    this.accentColor,
  });
  final String label;
  final IconData icon;
  final String route;
  final Color? accentColor;
}
