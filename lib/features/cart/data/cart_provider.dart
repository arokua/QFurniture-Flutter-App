import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../config/store_cart_api_service.dart';
import '../../../services/auth_service.dart';
import '../domain/cart_item.dart';
import 'store_cart_json.dart';
import 'store_cart_snapshot.dart';

/// Full WooCommerce Store API cart (`GET /wc/store/v1/cart`): line names, subtotals, shipping, total.
final storeCartFullProvider =
    FutureProvider.autoDispose<StoreCartApiSnapshot?>((ref) async {
  final cart = ref.watch(cartProvider);
  if (cart.isEmpty) return null;
  if (AuthService.instance.isWholesaleCartLocalOnly) return null;
  if (!StoreCartApiService.instance.hasSession) return null;
  final r = await StoreCartApiService.instance.fetchFullCart();
  if (!r.success || r.data == null) return null;
  return StoreCartApiSnapshot.fromCartJson(r.data!);
});

class CartNotifier extends StateNotifier<List<CartItem>> {
  static const _key = 'cart_items';

  /// Completes after local prefs + optional remote merge (avoids empty flash on cold start).
  late final Future<void> _loadFuture;

  CartNotifier() : super([]) {
    _loadFuture = _loadCart();
  }

  Future<void> ensureHydrated() => _loadFuture;

  Future<void> _loadCart() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        final decoded = list
            .map((e) => CartItem(
                  productId: e['productId'] as int,
                  quantity: e['quantity'] as int,
                ))
            .toList();
        // Avoid racing with user actions: if items were already added in-memory
        // while this async hydration was in-flight, don't clobber them.
        if (state.isEmpty) {
          state = decoded;
        }
      } catch (_) {}
    }

    // Remote sync: do not replace a non-empty local cart with an empty remote
    // (session cookie can point at a different guest cart than the one that had lines).
    if (StoreCartApiService.instance.hasSession &&
        !AuthService.instance.isWholesaleCartLocalOnly) {
      final remote = await StoreCartApiService.instance.fetchFullCart();
      if (remote.success && remote.data != null) {
        final remoteItems = cartItemsFromStoreCartJson(remote.data!);
        await StoreCartApiService.instance
            .absorbCartSessionFromCartJson(remote.data!);
        state = remoteItems;
        await _saveCart();
      }
    }
  }

  Future<void> _saveCart() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(state.map((e) => {
      'productId': e.productId,
      'quantity': e.quantity,
    }).toList());
    await prefs.setString(_key, raw);
  }

  void add(int productId, {int quantity = 1}) {
    final i = state.indexWhere((e) => e.productId == productId);
    if (i >= 0) {
      state = [
        ...state.sublist(0, i),
        state[i].copyWith(quantity: state[i].quantity + quantity),
        ...state.sublist(i + 1),
      ];
    } else {
      state = [...state, CartItem(productId: productId, quantity: quantity)];
    }
    _saveCart();
  }

  void setQuantity(int productId, int quantity) {
    if (quantity <= 0) {
      remove(productId);
      return;
    }
    final i = state.indexWhere((e) => e.productId == productId);
    if (i >= 0) {
      state = [
        ...state.sublist(0, i),
        state[i].copyWith(quantity: quantity),
        ...state.sublist(i + 1),
      ];
      _saveCart();
    }
  }

  void remove(int productId) {
    state = state.where((e) => e.productId != productId).toList();
    _saveCart();
  }

  void clear() {
    state = [];
    _saveCart();
  }

  /// Re-fetch cart items from remote (WooCommerce Store API) and update local state.
  /// Call this after WebView closes if [StoreCartApiService] has a session cookie.
  Future<void> refreshFromRemote() async {
    if (AuthService.instance.isWholesaleCartLocalOnly) return;
    if (!StoreCartApiService.instance.hasSession) return;
    try {
      final remote = await StoreCartApiService.instance.fetchFullCart();
      if (!remote.success || remote.data == null) return;
      final remoteItems = cartItemsFromStoreCartJson(remote.data!);
      await StoreCartApiService.instance
          .absorbCartSessionFromCartJson(remote.data!);
      state = remoteItems;
      await _saveCart();
    } catch (_) {
      // Keep local state as-is
    }
  }

  /// Apply cart line items from WebView `fetch('/wp-json/wc/store/v1/cart')` (works when cookies are HttpOnly).
  /// Replaces local lines with the server cart (including empty when the web cart was cleared).
  Future<void> applyStoreCartFromJson(Map<String, dynamic> json) async {
    final remoteItems = cartItemsFromStoreCartJson(json);
    state = remoteItems;
    await _saveCart();
  }

  /// After JWT login / registration: push persisted local lines to Store API **before** opening WebView
  /// so the server cart matches the app; then refresh from remote.
  Future<void> syncLocalCartToStoreAfterLogin() async {
    if (AuthService.instance.isWholesaleCartLocalOnly) return;
    if (state.isEmpty) return;
    try {
      final items = state
          .map((e) => (productId: e.productId, quantity: e.quantity))
          .toList();
      final ok = await StoreCartApiService.instance.syncCartToOnline(items);
      if (ok) {
        await refreshFromRemote();
      }
    } catch (_) {}
  }

  /// Reconcile local cart with remote line items (same as refresh).
  Future<void> syncStocks() async {
    await refreshFromRemote();
  }
}

final cartProvider =
    StateNotifierProvider<CartNotifier, List<CartItem>>((ref) => CartNotifier());

/// First load of [cartProvider] from disk + optional remote merge (no empty flash).
final cartHydratedProvider = FutureProvider<void>((ref) async {
  await ref.read(cartProvider.notifier).ensureHydrated();
});

/// Total number of items (sum of quantities).
int cartItemCount(List<CartItem> cart) {
  return cart.fold(0, (sum, e) => sum + e.quantity);
}
