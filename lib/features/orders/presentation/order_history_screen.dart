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

final orderHistoryProvider =
    FutureProvider.autoDispose<List<WooOrderSummary>>((ref) async {
  final auth = AuthService.instance;
  final s = auth.currentSession;
  final token = s?.token;
  if (token == null || token.isEmpty) return const [];

  final cid =
      s?.customerId ?? await auth.ensureCustomerIdForCurrentSession(force: true);
  if (cid == null) {
    throw Exception(
      'Could not resolve your store customer account. Try signing out and back in.',
    );
  }

  if (kDebugMode) {
    debugPrint('[OrderHistory] fetching orders for customerId=$cid');
  }

  return WooCommerceRestApi.instance.fetchCustomerOrders(
    jwt: token,
    customerId: cid,
  );
});

Future<void> reorderFromOrder(
  BuildContext context,
  WidgetRef ref,
  WooOrderSummary order,
) async {
  final session = AuthService.instance.currentSession;
  final token = session?.token;
  final cid = session?.customerId;
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
                error: (e, _) =>
                    Center(child: Text('Could not load orders: $e')),
                data: (orders) {
                  if (orders.isEmpty) {
                    return ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        SizedBox(height: 120),
                        Center(child: Text('No orders found yet.')),
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
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text('Order #${o.number}'),
                                subtitle: Text('$dateStr · ${o.statusLabel}'),
                                trailing: Text(
                                  formatStorePrice(total),
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleSmall
                                      ?.copyWith(fontWeight: FontWeight.bold),
                                ),
                                onTap: () {
                                  StoreWebViewScreen.push(
                                    context,
                                    storeOrderViewUrl(o.id),
                                    attemptWebLogin:
                                        AuthService.instance.currentSession !=
                                            null,
                                    useMobileLayout: true,
                                  );
                                },
                              ),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
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
