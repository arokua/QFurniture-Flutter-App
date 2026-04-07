import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../app_router.dart';
import '../config/store_cart_api_service.dart';
import '../features/cart/data/cart_provider.dart';
import '../features/catalog/presentation/product_list_screen.dart';
import '../services/auth_service.dart';
import 'categories_screen.dart';
import 'more_screen.dart';

/// Main shell with bottom tabs: Catalog, Categories, More.
class MainTabScreen extends ConsumerStatefulWidget {
  const MainTabScreen({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  ConsumerState<MainTabScreen> createState() => _MainTabScreenState();
}

class _MainTabScreenState extends ConsumerState<MainTabScreen>
    with WidgetsBindingObserver {
  late int _currentIndex;

  static const List<_TabItem> _tabs = [
    _TabItem(label: 'Catalog', icon: Icons.grid_view, route: AppRoutes.home),
    _TabItem(label: 'Categories', icon: Icons.category, route: AppRoutes.homeCategories),
    _TabItem(label: 'More', icon: Icons.more_horiz, route: AppRoutes.homeMore),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentIndex = widget.initialIndex.clamp(0, _tabs.length - 1);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshCartFromStoreIfPossible();
    }
  }

  Future<void> _refreshCartFromStoreIfPossible() async {
    if (!StoreCartApiService.instance.hasSession) return;
    if (AuthService.instance.isWholesaleCartLocalOnly) return;
    await ref.read(cartProvider.notifier).refreshFromRemote();
    ref.invalidate(storeCartFullProvider);
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
