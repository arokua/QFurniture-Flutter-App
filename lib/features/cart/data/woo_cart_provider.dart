import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../config/store_cart_api_service.dart';
import '../../../config/store_config.dart';
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

/// Fetches `/wp-json/wc/store/v1/cart` with the persisted Cart-Token / cookies.
class WooCartNotifier extends AsyncNotifier<WooCartState> {
  @override
  Future<WooCartState> build() => _fetch();

  Future<WooCartState> _fetch() async {
    if (!AuthService.instance.isSignedIn) return WooCartState.empty;

    await ensureCartJwtFresh();

    var state = await _fetchWithCurrentSession();
    if (state != null) return state;

    // Session may have expired — re-bootstrap once, then retry.
    if (kDebugMode) debugPrint('[WooCart] retry after session re-bootstrap');
    await rebootstrapCartSession();
    state = await _fetchWithCurrentSession();
    if (state != null) return state;

    throw Exception('Cart API unavailable — pull to refresh');
  }

  Future<WooCartState?> _fetchWithCurrentSession() async {
    final jwt = AuthService.instance.jwtToken ?? '';
    final cookie = StoreCartApiService.instance.cookie ?? '';
    final cartToken = StoreCartApiService.instance.cartToken ?? '';

    final headers = <String, String>{
      'Accept': 'application/json',
      'User-Agent': kAppUserAgent,
    };
    if (jwt.isNotEmpty) headers['Authorization'] = 'Bearer $jwt';
    if (cookie.isNotEmpty) headers['Cookie'] = cookie;
    if (cartToken.isNotEmpty) headers['Cart-Token'] = cartToken;

    final url = Uri.parse('$kStoreBaseUrl/wp-json/wc/store/v1/cart');
    if (kDebugMode) debugPrint('[WooCart] GET $url cartToken=${cartToken.isNotEmpty}');

    http.Response res;
    try {
      res = await http
          .get(url, headers: headers)
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      if (kDebugMode) debugPrint('[WooCart] network error: $e');
      return null;
    }

    if (kDebugMode) {
      debugPrint('[WooCart] → ${res.statusCode} len=${res.body.length}');
    }

    if (res.statusCode != 200) return null;

    await StoreCartApiService.instance.absorbResponseHeaders(res);

    final Map<String, dynamic> data;
    try {
      data = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      if (kDebugMode) debugPrint('[WooCart] JSON parse failed: $e');
      return null;
    }

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
