import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../app_router.dart';
import '../config/store_config.dart';
import '../config/store_link_service.dart';
import '../services/auth_service.dart';

String _accountRoleLabel(String role) {
  switch (role.toLowerCase()) {
    case 'customers':
    case 'customer':
      return 'CUSTOMER';
    case 'wholesale':
      return 'WHOLESALE';
    case 'dropshipping':
      return 'DROPSHIP';
    case 'retailer':
      return 'RETAILER';
    default:
      return role.toUpperCase();
  }
}

/// More tab: links to Cart, Favorites, and placeholders.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = AuthService.instance.currentSession;
    final guestBrowse = AuthService.instance.isGuestBrowse;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('More'),
        elevation: 0,
      ),
      body: ListView(
        children: [
          // User Profile Section
          if (guestBrowse && session == null)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Card(
                elevation: 0,
                color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.cloud_off_outlined, color: cs.primary),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Browsing without an account',
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Catalogue uses cached data when offline. Sign in to sync cart, checkout, and account.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          FilledButton.tonal(
                            onPressed: () => context.go(AppRoutes.login),
                            child: const Text('Sign in'),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () async {
                              await AuthService.instance.signOut();
                              if (context.mounted) {
                                context.go(AppRoutes.login);
                              }
                            },
                            child: const Text('End session'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (session != null)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Card(
                elevation: 0,
                color: cs.primaryContainer.withValues(alpha: 0.3),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 30,
                        backgroundColor: cs.primary,
                        child: Text(
                          session.displayName.isNotEmpty ? session.displayName[0].toUpperCase() : 'U',
                          style: TextStyle(color: cs.onPrimary, fontSize: 24, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              session.displayName,
                              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: cs.secondary,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                _accountRoleLabel(session.role),
                                style: TextStyle(color: cs.onSecondary, fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                            ),
                            Text(
                              session.email,
                              style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurface.withValues(alpha: 0.6)),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.logout),
                        onPressed: () async {
                          await AuthService.instance.signOut();
                          if (context.mounted) {
                            context.go(AppRoutes.login);
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const Divider(),
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
            leading: const Icon(Icons.person_outline),
            title: const Text('My account'),
            subtitle: const Text('Store account on qtoys.com.au'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final session = AuthService.instance.currentSession;
              if (session == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Sign in to open your store account.'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
                context.go(AppRoutes.login);
                return;
              }
              // Opens in the device browser (same cart/session UX as checkout).
              final url = storeMyAccountLoginUrl(
                accountType: AuthService.instance.webAccountTypeForStoreLogin,
              );
              await StoreLinkService.openUrl(url);
            },
          ),
          ListTile(
            leading: const Icon(Icons.lock_reset_outlined),
            title: const Text('Reset password'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => StoreLinkService.openPasswordReset(),
          ),
        ],
      ),
    );
  }
}
