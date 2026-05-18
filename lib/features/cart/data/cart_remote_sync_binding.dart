import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/auth_service.dart';
import 'woo_cart_provider.dart';

/// Refreshes the WooCommerce cart when the app returns to the foreground and
/// on a periodic interval so web-only cart edits propagate without opening Cart.
class CartRemoteSyncBinding extends ConsumerStatefulWidget {
  const CartRemoteSyncBinding({
    super.key,
    required this.child,
    this.periodicInterval = const Duration(minutes: 7),
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

  void _startPeriodic() {
    _periodic?.cancel();
    _periodic = Timer.periodic(widget.periodicInterval, (_) {
      if (!mounted) return;
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      if (!AuthService.instance.isSignedIn) return;
      ref.invalidate(wooCartProvider);
    });
  }

  void _invalidateCartIfSignedIn() {
    if (!AuthService.instance.isSignedIn) return;
    ref.invalidate(wooCartProvider);
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
