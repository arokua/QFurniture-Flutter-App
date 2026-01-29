import 'package:flutter_riverpod/flutter_riverpod.dart';

class FavoritesNotifier extends StateNotifier<Set<int>> {
  FavoritesNotifier() : super({});

  void toggle(int productId) {
    if (state.contains(productId)) {
      state = {...state}..remove(productId);
    } else {
      state = {...state, productId};
    }
  }

  void add(int productId) {
    state = {...state, productId};
  }

  void remove(int productId) {
    state = {...state}..remove(productId);
  }
}

final favoritesProvider =
    StateNotifierProvider<FavoritesNotifier, Set<int>>((ref) => FavoritesNotifier());
