import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/auth_service.dart';
import '../domain/cart_item.dart';
import 'cart_coordinator.dart';
import 'cart_providers.dart';

/// Local cart lines, projected from [CartCoordinator].
///
/// This used to be the cart's second independent owner: it wrote its own copy
/// to SharedPreferences while [CartSyncService] wrote a different copy to disk
/// under a different key scheme, with no ordering between them. Every method is
/// now a delegate, so there is exactly one writer.
///
/// The public surface is deliberately unchanged so existing widgets compile
/// untouched.
class CartNotifier extends StateNotifier<List<CartItem>> {
  CartNotifier(this._coordinator) : super(_coordinator.current.itemsView) {
    _sub = _coordinator.stream.listen((doc) {
      if (mounted) state = doc.itemsView;
    });
    AuthService.instance.addListener(_onAuthChanged);
  }

  final CartCoordinator _coordinator;
  StreamSubscription<void>? _sub;

  @override
  void dispose() {
    AuthService.instance.removeListener(_onAuthChanged);
    _sub?.cancel();
    super.dispose();
  }

  void _onAuthChanged() {
    // Switching users swaps the whole document; the coordinator owns that.
    _coordinator.onUserChanged().ignore();
  }

  Future<void> ensureHydrated() => _coordinator.ensureHydrated();

  void add(int productId, {int quantity = 1}) {
    _coordinator.add(productId, quantity: quantity).ignore();
  }

  void setQuantity(int productId, int quantity) {
    _coordinator.setQuantity(productId, quantity).ignore();
  }

  void remove(int productId) {
    _coordinator.remove(productId).ignore();
  }

  void clear() {
    _coordinator.clear().ignore();
  }

  /// Pulls the authoritative cart from the Store API.
  Future<void> refreshFromRemote() =>
      _coordinator.reconcile(force: true).then((_) {});

  /// Adopts a cart body pulled out of the WebView.
  Future<void> applyStoreCartFromJson(Map<String, dynamic> json) {
    final quantities = <int, int>{};
    final items = json['items'];
    if (items is List) {
      for (final e in items) {
        if (e is! Map) continue;
        final rawId = e['id'];
        final pid = rawId is int ? rawId : int.tryParse(rawId?.toString() ?? '');
        if (pid == null || pid <= 0) continue;
        final rawQty = e['quantity'];
        final qty =
            rawQty is int ? rawQty : int.tryParse(rawQty?.toString() ?? '') ?? 0;
        if (qty > 0) quantities[pid] = qty;
      }
    }
    return _coordinator.setExactLines(quantities);
  }

  /// Merges the guest basket into the signed-in cart.
  ///
  /// Returns as soon as the merge is persisted. It used to issue one sequential
  /// `addItem` request per line — up to four POSTs each — while the login
  /// button spun. The queue now drains in the background instead.
  Future<void> syncLocalCartToStoreAfterLogin() async {
    final quantities = <int, int>{
      for (final line in _coordinator.current.lines)
        line.productId: line.quantity,
    };
    await _coordinator.onUserChanged();
    if (quantities.isEmpty) return;
    await _coordinator.adoptCart(quantities);
  }
}

final cartProvider =
    StateNotifierProvider<CartNotifier, List<CartItem>>((ref) {
  final n = CartNotifier(cartCoordinator);
  ref.onDispose(n.dispose);
  return n;
});

/// First load of [cartProvider] from disk.
final cartHydratedProvider = FutureProvider<void>((ref) async {
  await ref.read(cartProvider.notifier).ensureHydrated();
});

int cartItemCount(List<CartItem> cart) {
  return cart.fold(0, (sum, e) => sum + e.quantity);
}
