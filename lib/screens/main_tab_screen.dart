import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../app_router.dart';
import '../features/catalog/presentation/product_list_screen.dart';
import 'categories_screen.dart';
import 'more_screen.dart';

/// Main shell with bottom tabs: Catalog, Categories, More.
class MainTabScreen extends StatefulWidget {
  const MainTabScreen({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  State<MainTabScreen> createState() => _MainTabScreenState();
}

class _MainTabScreenState extends State<MainTabScreen> {
  late int _currentIndex;

  static const List<_TabItem> _tabs = [
    _TabItem(label: 'Catalog', icon: Icons.grid_view, route: AppRoutes.home),
    _TabItem(label: 'Categories', icon: Icons.category, route: AppRoutes.homeCategories),
    _TabItem(label: 'More', icon: Icons.more_horiz, route: AppRoutes.homeMore),
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
      _currentIndex = widget.initialIndex;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: const [
          ProductListScreen(),
          CategoriesScreen(),
          MoreScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() => _currentIndex = index);
          context.go(_tabs[index].route);
        },
        destinations: _tabs
            .map((t) => NavigationDestination(
                  icon: Icon(t.icon),
                  label: t.label,
                ))
            .toList(),
      ),
    );
  }
}

class _TabItem {
  const _TabItem({required this.label, required this.icon, required this.route});
  final String label;
  final IconData icon;
  final String route;
}
