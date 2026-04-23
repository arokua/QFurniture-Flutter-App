import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../config/store_cart_api_service.dart';
import '../../../config/store_config.dart';
import '../../../services/auth_service.dart';
import '../domain/cart_item.dart';
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

/// Fetches `/wp-json/wc/store/v1/cart` directly — same approach as the
/// debug panel that returns 200 successfully.
/// Absorbs response headers (Nonce, Cart-Token) so the service layer can
/// use them for future POST requests (add/remove/update).
class WooCartNotifier extends AsyncNotifier<WooCartState> {
  @override
  Future<WooCartState> build() => _fetch();

  Future<WooCartState> _fetch() async {
    if (!AuthService.instance.isSignedIn) return WooCartState.empty;

    // Use every credential we have — mirrors the debug panel that works.
    final jwt = AuthService.instance.jwtToken ?? '';
    final cookie = StoreCartApiService.instance.cookie ?? '';
    final cartToken = StoreCartApiService.instance.cartToken ?? '';

    final headers = <String, String>{
      'Accept': 'application/json',
      'User-Agent': 'QToysApp/1.0',
    };
    if (jwt.isNotEmpty) headers['Authorization'] = 'Bearer $jwt';
    if (cookie.isNotEmpty) headers['Cookie'] = cookie;
    if (cartToken.isNotEmpty) headers['Cart-Token'] = cartToken;

    final url = Uri.parse('$kStoreBaseUrl/wp-json/wc/store/v1/cart');
    if (kDebugMode) debugPrint('[WooCart] GET $url');

    final res = await http
        .get(url, headers: headers)
        .timeout(const Duration(seconds: 15));

    if (kDebugMode) {
      debugPrint('[WooCart] → ${res.statusCode} len=${res.body.length}');
    }

    if (res.statusCode != 200) {
      throw Exception('Cart API returned ${res.statusCode}: ${res.body.length > 200 ? res.body.substring(0, 200) : res.body}');
    }

    // Absorb nonce + cart-token from response headers for future POSTs.
    await StoreCartApiService.instance.absorbResponseHeaders(res);

    final Map<String, dynamic> data;
    try {
      data = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      throw Exception('[WooCart] JSON parse failed: $e');
    }

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
