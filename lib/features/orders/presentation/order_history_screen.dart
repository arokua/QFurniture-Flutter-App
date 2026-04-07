import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../config/store_config.dart';
import '../../../services/auth_service.dart';
import '../../../services/woo_commerce_rest_api.dart';
import '../../catalog/presentation/store_webview_screen.dart';
import '../domain/woo_order_summary.dart';

final orderHistoryProvider =
    FutureProvider.autoDispose<List<WooOrderSummary>>((ref) async {
  final s = AuthService.instance.currentSession;
  final token = s?.token;
  final cid = s?.customerId;
  if (token == null || token.isEmpty || cid == null) return const [];
  return WooCommerceRestApi.instance.fetchCustomerOrders(
    jwt: token,
    customerId: cid,
  );
});

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
      body: session?.customerId == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Your account is not linked to a WooCommerce customer id yet, '
                  'so orders cannot be loaded here. Open My account on the store to view orders.',
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
                error: (e, _) => Center(child: Text('Could not load orders: $e')),
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
                      final dateStr = DateFormat.yMMMd().add_jm().format(o.dateCreated.toLocal());
                      return Card(
                        child: ListTile(
                          title: Text('Order #${o.number}'),
                          subtitle: Text('$dateStr · ${o.statusLabel}'),
                          trailing: Text(
                            '${o.currency} ${o.total}',
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          onTap: () {
                            StoreWebViewScreen.push(
                              context,
                              storeOrderViewUrl(o.id),
                              attemptWebLogin: AuthService.instance.currentSession != null,
                            );
                          },
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
