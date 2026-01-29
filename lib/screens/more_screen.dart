import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../app_router.dart';

/// More tab: links to Cart, Favorites, and placeholders.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('More'),
        elevation: 0,
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.shopping_cart_outlined),
            title: const Text('Cart'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.cart),
          ),
          ListTile(
            leading: const Icon(Icons.favorite_border),
            title: const Text('Favorites'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.favorites),
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Settings coming soon')),
              );
            },
          ),
        ],
      ),
    );
  }
}
