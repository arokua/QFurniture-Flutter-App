import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app_router.dart';
import '../../../config/store_cart_api_service.dart';
import '../../../config/store_config.dart';
import '../../../providers.dart';
import '../../../services/auth_service.dart';
import '../../../services/order_history_cache_service.dart';
import '../../../services/order_history_sync_service.dart';
import '../../../services/woo_commerce_rest_api.dart';
import '../../cart/data/cart_provider.dart';
import '../../cart/data/woo_cart_provider.dart';
import '../../catalog/presentation/store_webview_screen.dart';
import '../domain/order_history_load_result.dart';
import '../domain/woo_order_summary.dart';

final orderHistoryProvider =
    AsyncNotifierProvider.autoDispose<OrderHistoryNotifier, OrderHistoryLoadResult>(
  OrderHistoryNotifier.new,
);

class OrderHistoryNotifier extends AutoDisposeAsyncNotifier<OrderHistoryLoadResult> {
  @override
  Future<OrderHistoryLoadResult> build() async {
    final auth = AuthService.instance;
    await auth.ensureValidSession();
    final session = auth.currentSession;
    final token = session?.token;
    if (token == null || token.isEmpty) {
      return const OrderHistoryLoadResult(orders: []);
    }

    final userKey = await OrderHistorySyncService.instance.currentUserKey();
    if (userKey == null) {
      return const OrderHistoryLoadResult(orders: []);
    }

    final cached =
        await OrderHistoryCacheService.instance.readOrders(userKey);
    if (cached.isNotEmpty) {
      unawaited(_refreshInBackground());
      return OrderHistoryLoadResult(orders: cached);
    }

    final synced = await OrderHistorySyncService.instance.syncNow(force: true);
    if (synced != null) return synced;

    return const OrderHistoryLoadResult(orders: []);
  }

  Future<void> _refreshInBackground() async {
    final fresh = await OrderHistorySyncService.instance.syncNow(force: true);
    if (fresh == null) return;
    final current = state.valueOrNull;
    if (current == null) {
      state = AsyncData(fresh);
      return;
    }
    if (_ordersChanged(current.orders, fresh.orders) ||
        current.webViewFallback != fresh.webViewFallback) {
      state = AsyncData(fresh);
    }
  }

  bool _ordersChanged(List<WooOrderSummary> a, List<WooOrderSummary> b) {
    if (a.length != b.length) return true;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id ||
          a[i].status != b[i].status ||
          a[i].syncState != b[i].syncState) {
        return true;
      }
    }
    return false;
  }

  Future<void> silentRefresh() => _refreshInBackground();
}

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
