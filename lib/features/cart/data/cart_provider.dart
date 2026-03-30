import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../config/store_cart_api_service.dart';
import '../domain/cart_item.dart';
import 'store_cart_json.dart';

/// Store API totals/shipping (after [cartProvider] changes, when session exists).
final storeCartTotalsProvider =
    FutureProvider.autoDispose<StoreCartTotalsView?>((ref) async {
  final cart = ref.watch(cartProvider);
  if (cart.isEmpty) return null;
  if (!StoreCartApiService.instance.hasSession) return null;
  final r = await StoreCartApiService.instance.fetchFullCart();
  if (!r.success || r.data == null) return null;
  return StoreCartTotalsView.fromCartJson(r.data!);
});

class CartNotifier extends StateNotifier<List<CartItem>> {
  CartNotifier() : super([]) {
    _loadCart();
  }

  static const _key = 'cart_items';

  Future<void> _loadCart() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        state = list.map((e) => CartItem(
          productId: e['productId'] as int,
          quantity: e['quantity'] as int,
        )).toList();
      } catch (_) {}
    }
    
    // Remote sync: full cart GET distinguishes success vs failure (avoid wiping on error).
    if (StoreCartApiService.instance.hasSession) {
      final remote = await StoreCartApiService.instance.fetchFullCart();
      if (remote.success && remote.data != null) {
        state = cartItemsFromStoreCartJson(remote.data!);
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
    if (!StoreCartApiService.instance.hasSession) return;
    try {
      final remote = await StoreCartApiService.instance.fetchFullCart();
      if (!remote.success || remote.data == null) return;
      state = cartItemsFromStoreCartJson(remote.data!);
      await _saveCart();
    } catch (_) {
      // Keep local state as-is
    }
  }

  /// Apply cart line items from WebView `fetch('/wp-json/wc/store/v1/cart')` (works when cookies are HttpOnly).
  Future<void> applyStoreCartFromJson(Map<String, dynamic> json) async {
    state = cartItemsFromStoreCartJson(json);
    await _saveCart();
  }

  /// Reconcile local cart with remote line items (same as refresh).
  Future<void> syncStocks() async {
    await refreshFromRemote();
  }
}

final cartProvider =
    StateNotifierProvider<CartNotifier, List<CartItem>>((ref) => CartNotifier());

/// Total number of items (sum of quantities).
int cartItemCount(List<CartItem> cart) {
  return cart.fold(0, (sum, e) => sum + e.quantity);
}
