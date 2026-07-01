import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../config/store_config.dart';
import '../../../services/auth_service.dart';
import '../../../utils/money_format.dart';
import '../../catalog/presentation/store_webview_screen.dart';
import 'order_history_notifier.dart';

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
                await ref.read(orderHistoryProvider.notifier).silentRefresh();
              },
              child: async.when(
                loading: () => const _OrderHistorySkeleton(),
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
                        const SizedBox(height: 8),
                        Center(
                          child: Text(
                            'Trashed orders are not shown here. '
                            'Pull down to refresh after placing a new order.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
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

class _OrderHistorySkeleton extends StatelessWidget {
  const _OrderHistorySkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: List.generate(
        4,
        (_) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Card(
            child: SizedBox(
              height: 88,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            height: 14,
                            width: 120,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade300,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            height: 12,
                            width: 180,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade200,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      height: 14,
                      width: 56,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
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
