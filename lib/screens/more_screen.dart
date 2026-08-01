import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../app_router.dart';
import '../features/auth/presentation/change_password_screen.dart';
import '../services/auth_service.dart';

String _accountRoleLabel(String role) {
  switch (role.toLowerCase()) {
    case 'customers':
    case 'customer':
      return 'CUSTOMER';
    case 'wholesale':
    case 'wholesale_customer':
      return 'WHOLESALE';
    case 'wholesale_childcare':
      return 'WHOLESALE (CHILDCARE)';
    case 'dropshipping':
      return 'DROPSHIP / RETAIL';
    case 'retailer':
      return 'RETAILER';
    default:
      return role.toUpperCase();
  }
}

/// Profile tab: cart and account tools.
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
        title: const Text('Profile'),
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
                          Icon(Icons.storefront_outlined, color: cs.primary),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Browsing the catalogue',
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Prices shown are retail reference. Partners can sign in for trade pricing and account tools.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.tonal(
                        onPressed: () => context.go(AppRoutes.login),
                        child: const Text('Partner sign in'),
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
                            context.go(AppRoutes.home);
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
          // "My account" is hidden for now. Kept here rather than deleted so it
          // can be restored, and because it is the last WebView entry point on
          // this screen (see localDocs/deferred-backlog.txt D1).
          //
          // To restore, re-add these imports:
          //   import '../config/store_config.dart';
          //   import '../features/catalog/presentation/store_webview_screen.dart';
          // ListTile(
          //   leading: const Icon(Icons.person_outline),
          //   title: const Text('My account'),
          //   subtitle: const Text('Store account on qtoys.com.au'),
          //   trailing: const Icon(Icons.chevron_right),
          //   onTap: () {
          //     final session = AuthService.instance.currentSession;
          //     final url = session != null
          //         ? storeMyAccountUrl
          //         : storeMyAccountLoginUrl(
          //             accountType:
          //                 AuthService.instance.webAccountTypeForStoreLogin,
          //           );
          //     StoreWebViewScreen.push(
          //       context,
          //       url,
          //       attemptWebLogin: session != null,
          //       useMobileLayout: true,
          //     );
          //   },
          // ),
          if (session != null)
            ListTile(
              leading: const Icon(Icons.lock_reset_outlined),
              title: const Text('Change password'),
              trailing: const Icon(Icons.chevron_right),
              // Fully in-app. This used to hand off to the storefront in the
              // system browser, which the client did not want.
              onTap: () => ChangePasswordScreen.push(context),
            ),
          if (session != null)
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('Order history'),
              subtitle: const Text('View and reorder past invoices'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(AppRoutes.orders),
            ),
        ],
      ),
    );
  }
}
