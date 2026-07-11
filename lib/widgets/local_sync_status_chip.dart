import 'package:flutter/material.dart';

import '../config/local_first_sync_config.dart';
import '../services/cart_cache_service.dart';
import '../features/orders/domain/woo_order_summary.dart';

/// Dev/QA sync badge — hidden unless [LocalFirstSyncConfig.showSyncStatusAndLogging].
class LocalSyncStatusChip extends StatelessWidget {
  const LocalSyncStatusChip.cart({
    super.key,
    required this.status,
    this.error,
    this.fromCache = false,
  })  : order = null;

  const LocalSyncStatusChip.order({
    super.key,
    required WooOrderSummary this.order,
  })  : status = null,
        error = null,
        fromCache = false;

  final CartSyncStatus? status;
  final String? error;
  final bool fromCache;
  final WooOrderSummary? order;

  @override
  Widget build(BuildContext context) {
    if (!LocalFirstSyncConfig.showSyncStatusAndLogging) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    late final String label;
    late final Color bg;
    late final Color fg;

    if (order != null) {
      switch (order!.syncState) {
        case OrderSyncState.pending:
          label = 'Order sync: pending';
          bg = Colors.amber.shade100;
          fg = Colors.amber.shade900;
        case OrderSyncState.failed:
          label = 'Order sync: failed';
          bg = theme.colorScheme.errorContainer;
          fg = theme.colorScheme.onErrorContainer;
        case OrderSyncState.synced:
          label = 'Order sync: ok';
          bg = Colors.green.shade100;
          fg = Colors.green.shade900;
      }
    } else {
      final s = status ?? CartSyncStatus.idle;
      label = switch (s) {
        CartSyncStatus.idle => 'Cart: local',
        CartSyncStatus.pending => 'Cart sync: pending',
        CartSyncStatus.syncing => 'Cart sync: syncing…',
        CartSyncStatus.synced =>
          fromCache ? 'Cart: cached (synced)' : 'Cart sync: ok',
        CartSyncStatus.failed => 'Cart sync: failed',
      };
      bg = switch (s) {
        CartSyncStatus.failed => theme.colorScheme.errorContainer,
        CartSyncStatus.syncing || CartSyncStatus.pending => Colors.amber.shade100,
        CartSyncStatus.synced => Colors.green.shade100,
        CartSyncStatus.idle => theme.colorScheme.surfaceContainerHighest,
      };
      fg = switch (s) {
        CartSyncStatus.failed => theme.colorScheme.onErrorContainer,
        CartSyncStatus.syncing || CartSyncStatus.pending => Colors.amber.shade900,
        CartSyncStatus.synced => Colors.green.shade900,
        CartSyncStatus.idle => theme.colorScheme.onSurfaceVariant,
      };
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Chip(
            visualDensity: VisualDensity.compact,
            label: Text(label, style: TextStyle(fontSize: 11, color: fg)),
            backgroundColor: bg,
            side: BorderSide.none,
          ),
          if (error != null && error!.isNotEmpty)
            Text(
              error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
                fontSize: 10,
              ),
            ),
          if (order?.syncError != null && order!.syncError!.isNotEmpty)
            Text(
              order!.syncError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
                fontSize: 10,
              ),
            ),
        ],
      ),
    );
  }
}
