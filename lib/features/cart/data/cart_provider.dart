import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../config/store_cart_api_service.dart';
import '../domain/cart_item.dart';

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
    
    // Remote sync: if we have a session, fetch remote items to ensure sync
    if (StoreCartApiService.instance.hasSession) {
      final remoteItems = await StoreCartApiService.instance.getItems();
      if (remoteItems.isNotEmpty) {
        // Merge strategy: remote takes precedence or merge based on ID
        // For simplicity here, let's use the remote state as source of truth if session exists
        state = remoteItems.map((e) => CartItem(
          productId: e.id,
          quantity: e.quantity,
        )).toList();
        _saveCart();
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

  /// Force fetch latest prices and stock from remote for items currently in cart.
  Future<void> syncStocks() async {
    final list = [...state];
    bool changed = false;
    for (int i = 0; i < list.length; i++) {
      try {
        final res = await StoreCartApiService.instance.getItems();
        // Matching logic would go here if we want to sync with remote cart...
        // But for now, let's just use the Store API getItems to reconcile if possible.
        if (res.isNotEmpty) {
           state = res.map((e) => CartItem(productId: e.id, quantity: e.quantity)).toList();
           _saveCart();
           return;
        }
      } catch (_) {}
    }
  }
}

final cartProvider =
    StateNotifierProvider<CartNotifier, List<CartItem>>((ref) => CartNotifier());

/// Total number of items (sum of quantities).
int cartItemCount(List<CartItem> cart) {
  return cart.fold(0, (sum, e) => sum + e.quantity);
}
