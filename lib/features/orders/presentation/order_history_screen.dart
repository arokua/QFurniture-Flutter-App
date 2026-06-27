import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app_router.dart';
import '../../../config/store_config.dart';
import '../../../config/store_cart_api_service.dart';
import '../../../providers.dart';
import '../../../services/auth_service.dart';
import '../../../services/woo_commerce_rest_api.dart';
import '../../../utils/money_format.dart';
import '../../cart/data/cart_provider.dart';
import '../../cart/data/woo_cart_provider.dart';
import '../../catalog/presentation/store_webview_screen.dart';
import '../domain/woo_order_summary.dart';

class OrderHistoryLoadResult {
  const OrderHistoryLoadResult({
    required this.orders,
    this.webViewFallback = false,
  });

  final List<WooOrderSummary> orders;
  final bool webViewFallback;
}

final orderHistoryProvider =
    FutureProvider.autoDispose<OrderHistoryLoadResult>((ref) async {
  final auth = AuthService.instance;
  final s = auth.currentSession;
  final token = s?.token;
  if (token == null || token.isEmpty) {
    return const OrderHistoryLoadResult(orders: []);
  }

  final qtoys = await WooCommerceRestApi.instance.fetchOrdersViaQtoysJwt(token);
  if (qtoys.reached) {
    if (kDebugMode) {
      debugPrint('[OrderHistory] qtoys/my-orders → ${qtoys.orders.length} orders');
    }
    return OrderHistoryLoadResult(orders: qtoys.orders);
  }

  final cid =
      s?.customerId ?? await auth.ensureCustomerIdForCurrentSession(force: true);
  if (cid == null) {
    if (kDebugMode) {
      debugPrint('[OrderHistory] customer id unresolved — WebView fallback');
    }
    return const OrderHistoryLoadResult(orders: [], webViewFallback: true);
  }

  if (kDebugMode) {
    debugPrint('[OrderHistory] fetching wc/v3 orders for customerId=$cid');
  }

  final orders = await WooCommerceRestApi.instance.fetchCustomerOrders(
    jwt: token,
    customerId: cid,
  );
  return OrderHistoryLoadResult(orders: orders);
});

Future<void> reorderFromOrder(
  BuildContext context,
  WidgetRef ref,
  WooOrderSummary order,
) async {
  final session = AuthService.instance.currentSession;
  final token = session?.token;
  var cid = session?.customerId;
  cid ??= await AuthService.instance.ensureCustomerIdForCurrentSession();
  if (token == null || token.isEmpty || cid == null) return;

  WooOrderSummary detail = order;
  if (order.lineItems.isEmpty) {
    final d = await WooCommerceRestApi.instance.fetchOrderById(
      jwt: token,
      orderId: order.id,
      customerId: cid,
    );
    if (d == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load order lines.')),
        );
      }
      return;
    }
    detail = d;
  }

  final repo = ref.read(productRepoProvider);
  final merged = <int, int>{};
  for (final line in detail.lineItems) {
    if (line.productId <= 0 || line.quantity <= 0) continue;
    merged[line.productId] = (merged[line.productId] ?? 0) + line.quantity;
  }

  final shortfalls = <String>[];
  final toAdd = <({int productId, int qty})>[];

  for (final e in merged.entries) {
    final productId = e.key;
    final requested = e.value;
    final p = await repo.getById(productId);
    if (p == null) {
      shortfalls.add('Product #$productId is no longer in the catalogue.');
      continue;
    }
    if (!p.inStock) {
      shortfalls.add('${p.name}: out of stock.');
      continue;
    }
    final avail = p.parsedStockQuantityApprox;
    if (avail != null && requested > avail) {
      shortfalls.add(
        '${p.name}: only $avail available (order had $requested).',
      );
      toAdd.add((productId: productId, qty: avail));
    } else {
      toAdd.add((productId: productId, qty: requested));
    }
  }

  toAdd.removeWhere((e) => e.qty <= 0);

  if (toAdd.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            shortfalls.isEmpty
                ? 'Nothing could be added to the cart.'
                : shortfalls.join('\n'),
          ),
        ),
      );
    }
    return;
  }

  if (shortfalls.isNotEmpty && context.mounted) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stock availability'),
        content: SingleChildScrollView(
          child: Text(
            '${shortfalls.join('\n')}\n\n'
            'Add available quantities to your cart?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Add to cart'),
          ),
        ],
      ),
    );
    if (ok != true) return;
  }

  final cart = ref.read(cartProvider.notifier);
  for (final t in toAdd) {
    cart.add(t.productId, quantity: t.qty);
    await StoreCartApiService.instance.addItem(t.productId, quantity: t.qty);
  }
  ref.invalidate(wooCartProvider);

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Added ${toAdd.length} product line(s). Open cart to checkout.',
        ),
      ),
    );
    context.push(AppRoutes.cart);
  }
}

void openOrderHistoryWebView(BuildContext context) {
  StoreWebViewScreen.push(
    context,
    storeMyAccountOrdersUrl,
    attemptWebLogin: AuthService.instance.currentSession != null,
    useMobileLayout: true,
  );
}

class OrderHistoryScreen extends ConsumerWidget {
  const OrderHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(orderHistoryProvider);
    final session = AuthService.instance.currentSession;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Order history'),
        elevation: 0,
        actions: [
          if (session != null)
            IconButton(
              tooltip: 'View on website',
              icon: const Icon(Icons.open_in_browser_outlined),
              onPressed: () => openOrderHistoryWebView(context),
            ),
        ],
      ),
      body: (session == null)
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Sign in to view your order history.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(orderHistoryProvider);
                await ref.read(orderHistoryProvider.future);
              },
              child: async.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => _OrderHistoryFallback(
                  message: 'Could not load orders: $e',
                  onOpenWebView: () => openOrderHistoryWebView(context),
                ),
                data: (result) {
                  if (result.webViewFallback) {
                    return ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        _OrderHistoryFallback(
                          message:
                              'We could not link your account for in-app order history. '
                              'You can still view orders on the store website.',
                          onOpenWebView: () => openOrderHistoryWebView(context),
                        ),
                      ],
                    );
                  }

                  final orders = result.orders;
                  if (orders.isEmpty) {
                    return ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 80),
                        const Center(child: Text('No orders found yet.')),
                        const SizedBox(height: 16),
                        Center(
                          child: OutlinedButton.icon(
                            onPressed: () => openOrderHistoryWebView(context),
                            icon: const Icon(Icons.open_in_browser_outlined),
                            label: const Text('View orders on website'),
                          ),
                        ),
                      ],
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: orders.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final o = orders[i];
                      final dateStr = DateFormat.yMMMd()
                          .add_jm()
                          .format(o.dateCreated.toLocal());
                      final total = double.tryParse(o.total) ?? 0;
                      return Card(
                        clipBehavior: Clip.antiAlias,
                        child: Theme(
                          data: Theme.of(context).copyWith(
                            dividerColor: Colors.transparent,
                          ),
                          child: ExpansionTile(
                            tilePadding:
                                const EdgeInsets.fromLTRB(16, 8, 16, 0),
                            childrenPadding:
                                const EdgeInsets.fromLTRB(16, 0, 8, 12),
                            title: Text(
                              'Order #${o.number}',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text('$dateStr · ${o.statusLabel}'),
                            ),
                            trailing: Text(
                              formatStorePrice(total),
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            children: [
                              if (o.lineItems.isEmpty)
                                const ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text('Open on website for full details.'),
                                )
                              else
                                ...o.lineItems.map(
                                  (line) => ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(line.name),
                                    trailing: Text('×${line.quantity}'),
                                  ),
                                ),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton.icon(
                                    icon: const Icon(Icons.open_in_new, size: 18),
                                    label: const Text('View'),
                                    onPressed: () {
                                      StoreWebViewScreen.push(
                                        context,
                                        storeOrderViewUrl(o.id),
                                        attemptWebLogin:
                                            AuthService.instance
                                                    .currentSession !=
                                                null,
                                        useMobileLayout: true,
                                      );
                                    },
                                  ),
                                  TextButton.icon(
                                    icon: const Icon(Icons.replay, size: 18),
                                    label: const Text('Place same order'),
                                    onPressed: () =>
                                        reorderFromOrder(context, ref, o),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
    );
  }
}

class _OrderHistoryFallback extends StatelessWidget {
  const _OrderHistoryFallback({
    required this.message,
    required this.onOpenWebView,
  });

  final String message;
  final VoidCallback onOpenWebView;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.receipt_long_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onOpenWebView,
              icon: const Icon(Icons.open_in_browser_outlined),
              label: const Text('View orders on website'),
            ),
          ],
        ),
      ),
    );
  }
}
