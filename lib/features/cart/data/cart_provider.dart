import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/cart_item.dart';

class CartNotifier extends StateNotifier<List<CartItem>> {
  CartNotifier() : super([]);

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
    }
  }

  void remove(int productId) {
    state = state.where((e) => e.productId != productId).toList();
  }

  void clear() {
    state = [];
  }
}

final cartProvider =
    StateNotifierProvider<CartNotifier, List<CartItem>>((ref) => CartNotifier());

/// Total number of items (sum of quantities).
int cartItemCount(List<CartItem> cart) {
  return cart.fold(0, (sum, e) => sum + e.quantity);
}
