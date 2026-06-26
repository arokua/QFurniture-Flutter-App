import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config/store_cart_api_service.dart';
import '../../../services/auth_service.dart';
import '../domain/cart_item.dart';
import 'cart_session_refresh.dart';
import 'store_cart_json.dart';
import 'store_cart_snapshot.dart';

/// Full cart state returned by the WooCommerce Store API.
class WooCartState {
  const WooCartState({
    required this.items,
    this.snapshot,
    this.rawJson,
  });

  final List<CartItem> items;
  final StoreCartApiSnapshot? snapshot;
  final Map<String, dynamic>? rawJson;

  bool get isEmpty => items.isEmpty;

  static const empty = WooCartState(items: []);
}

/// Fetches `/wp-json/wc/store/v1/cart` via [StoreCartApiService] after
/// refreshing the JWT + cookie bridge session.
class WooCartNotifier extends AsyncNotifier<WooCartState> {
  @override
  Future<WooCartState> build() => _fetch();

  Future<WooCartState> _fetch() async {
    if (!AuthService.instance.isSignedIn) return WooCartState.empty;

    await refreshCartSession();

    var remote = await StoreCartApiService.instance.fetchFullCart();
    if (!remote.success || remote.data == null) {
      await StoreCartApiService.instance
          .bootstrapSessionFromJwt(AuthService.instance.jwtToken);
      remote = await StoreCartApiService.instance.fetchFullCart();
    }

    if (!remote.success || remote.data == null) {
      final previous = state.valueOrNull;
      if (previous != null &&
          previous.snapshot != null &&
          !previous.isEmpty) {
        if (kDebugMode) {
          debugPrint(
            '[WooCart] fetch failed — showing last synced cart '
            '(${previous.items.length} items)',
          );
        }
        return previous;
      }
      throw Exception('Cart API unavailable — pull to refresh');
    }

    final data = remote.data!;
    await StoreCartApiService.instance.absorbCartSessionFromCartJson(data);

    final items = cartItemsFromStoreCartJson(data);
    final snapshot = StoreCartApiSnapshot.fromCartJson(data);

    if (kDebugMode) debugPrint('[WooCart] parsed ${items.length} items');

    return WooCartState(items: items, snapshot: snapshot, rawJson: data);
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetch);
  }
}

final wooCartProvider =
    AsyncNotifierProvider<WooCartNotifier, WooCartState>(WooCartNotifier.new);
