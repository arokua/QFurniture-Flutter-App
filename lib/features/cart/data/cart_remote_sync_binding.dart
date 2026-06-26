import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/auth_service.dart';
import 'cart_provider.dart';
import 'cart_session_refresh.dart';
import 'woo_cart_provider.dart';

/// Refreshes the WooCommerce cart when the app returns to the foreground and
/// on a periodic interval so web-only cart edits propagate without opening Cart.
class CartRemoteSyncBinding extends ConsumerStatefulWidget {
  const CartRemoteSyncBinding({
    super.key,
    required this.child,
    this.periodicInterval = const Duration(minutes: 3),
  });

  final Widget child;
  final Duration periodicInterval;

  @override
  ConsumerState<CartRemoteSyncBinding> createState() =>
      _CartRemoteSyncBindingState();
}

class _CartRemoteSyncBindingState extends ConsumerState<CartRemoteSyncBinding>
    with WidgetsBindingObserver {
  Timer? _periodic;
  bool _syncInFlight = false;

  Future<void> _syncRemoteCart() async {
    if (!mounted || _syncInFlight) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    if (!AuthService.instance.isSignedIn) return;

    _syncInFlight = true;
    try {
      await refreshCartSession();
      if (!mounted) return;
      ref.invalidate(wooCartProvider);
      try {
        await ref.read(wooCartProvider.future);
      } catch (_) {}
      if (!mounted) return;
      await ref.read(cartProvider.notifier).refreshFromRemote();
    } finally {
      _syncInFlight = false;
    }
  }

  void _startPeriodic() {
    _periodic?.cancel();
    _periodic = Timer.periodic(widget.periodicInterval, (_) {
      _syncRemoteCart();
    });
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
      _syncRemoteCart();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
