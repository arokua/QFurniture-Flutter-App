import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config/local_first_sync_config.dart';
import '../../../services/auth_service.dart';
import '../../../services/order_history_sync_service.dart';
import 'cart_coordinator.dart';
import 'cart_providers.dart';

/// Refreshes the WooCommerce cart when the app returns to the foreground and
/// on a periodic interval so web-only cart edits propagate without opening Cart.
///
/// This is the **only** cart heartbeat in the app. `CartSyncService.init()`
/// used to start a second timer on the same interval; the two raced, and the
/// loser was rejected by the in-flight guard and surfaced as a sync error.
class CartRemoteSyncBinding extends ConsumerStatefulWidget {
  const CartRemoteSyncBinding({
    super.key,
    required this.child,
    this.periodicInterval,
  });

  final Widget child;

  /// Defaults to [LocalFirstSyncConfig.cartSyncInterval] so the heartbeat and
  /// the `syncNow` throttle cannot drift apart.
  final Duration? periodicInterval;

  @override
  ConsumerState<CartRemoteSyncBinding> createState() =>
      _CartRemoteSyncBindingState();
}

class _CartRemoteSyncBindingState extends ConsumerState<CartRemoteSyncBinding>
    with WidgetsBindingObserver {
  Timer? _periodic;

  void _startPeriodic() {
    _periodic?.cancel();
    final interval =
        widget.periodicInterval ?? LocalFirstSyncConfig.cartSyncInterval;
    _periodic = Timer.periodic(interval, (_) {
      if (!mounted) return;
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      if (!AuthService.instance.isSignedIn) return;
      cartCoordinator.reconcile(reason: ReconcileReason.manual).ignore();
      OrderHistorySyncService.instance.syncNow().ignore();
    });
  }

  void _invalidateCartIfSignedIn() {
    if (!AuthService.instance.isSignedIn) return;
    // The coordinator pushes the new document down its stream, so there is
    // nothing to invalidate — wooCartProvider is a view over it.
    cartCoordinator
        .reconcile(force: true, reason: ReconcileReason.appResume)
        .ignore();
    OrderHistorySyncService.instance.syncNow().ignore();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startPeriodic();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _periodic?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _invalidateCartIfSignedIn();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
