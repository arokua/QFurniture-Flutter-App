import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'store_config.dart';

/// WooCommerce Store API (wc/store/v1) cart: add, remove, update.
/// Cart is session-based; we persist cookie from first add so remove/update work.
/// Endpoints: POST add-item, GET items, DELETE items/:key, PUT items/:key.
class StoreCartApiService {
  StoreCartApiService._();
  static final StoreCartApiService instance = StoreCartApiService._();

  static String get _base => '$kStoreBaseUrl/wp-json/wc/store/v1';
  static Uri get _cartItems => Uri.parse('$_base/cart/items');
  static Uri get _cartAddItem => Uri.parse('$_base/cart/add-item');
  static Uri get _cartRoot => Uri.parse('$_base/cart');

  String? _cookie;
  /// WooCommerce Store API nonce from `X-WC-Store-API-Nonce` (required by many hosts for POST /cart/*).
  String? _storeApiNonce;
  /// WooCommerce Store API cart token (used instead of cookies/nonces for headless cart sessions).
  /// Header name: `Cart-Token`.
  String? _cartToken;
  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _cookie = _prefs?.getString('cart_session_cookie');
    // Nonce is not persisted: stale nonces cause POST /cart/add-item to fail after restarts.
    _cartToken = _prefs?.getString('cart_cart_token');
  }

  /// True when we have enough info to call the Store API for this cart.
  /// Cart-Token can replace cookies for headless cart sessions.
  bool get hasSession =>
      (_cookie != null && _cookie!.isNotEmpty) ||
      (_cartToken != null && _cartToken!.isNotEmpty);

  /// Expose the current session cookie for WebView injection.
  String? get cookie => _cookie;

  /// Set cookie from external source (e.g. WebView).
  Future<void> setCookie(String cookie) async {
    _cookie = _mergeCookiesPreservingSession(existing: _cookie, incoming: cookie);
    await _prefs?.setString('cart_session_cookie', _cookie ?? cookie);
  }

  Future<void> setCookieFromResponse(http.Response response) async {
    final setCookie = response.headers['set-cookie'];
    if (setCookie != null && setCookie.isNotEmpty) {
      _cookie =
          setCookie.split(',').map((s) => s.trim().split(';').first).join('; ');
      await _prefs?.setString('cart_session_cookie', _cookie!);
    }
  }

  void _captureNonceFromResponse(http.Response response) {
    // package:http lowercases header keys
    String? foundNonce;
    String? foundCartToken;
    for (final entry in response.headers.entries) {
      final key = entry.key.toLowerCase();
      final v = entry.value;
      if (v.trim().isEmpty) continue;

      if (key.contains('cart-token')) {
        foundCartToken ??= v.trim();
        continue;
      }
      if (key.contains('nonce')) {
        foundNonce ??= v.trim();
      }
    }
    if (foundNonce != null) {
      _storeApiNonce = foundNonce;
      if (kDebugMode) debugPrint('[StoreCart] captured Nonce len=${foundNonce.length}');
    }
    if (foundCartToken != null) {
      _cartToken = foundCartToken;
      // Cart tokens can persist; they avoid cookie splitting and nonce requirements.
      _prefs?.setString('cart_cart_token', _cartToken!);
      if (kDebugMode) debugPrint('[StoreCart] captured Cart-Token len=${foundCartToken.length}');
    }
    if (kDebugMode) {
      final noncePresent = _storeApiNonce != null && _storeApiNonce!.isNotEmpty;
      final cartTokenPresent = _cartToken != null && _cartToken!.isNotEmpty;
      if (!noncePresent && !cartTokenPresent) {
        final nonceKeys = response.headers.keys
            .where((k) => k.toLowerCase().contains('nonce'))
            .toList();
        final cartTokenKeys = response.headers.keys
            .where((k) => k.toLowerCase().contains('cart-token'))
            .toList();
        debugPrint(
          '[StoreCart] no Nonce/Cart-Token in headers; nonceKeys=$nonceKeys cartTokenKeys=$cartTokenKeys',
        );
      }
    }
  }

  Future<void> _absorbResponse(http.Response response) async {
    await setCookieFromResponse(response);
    _captureNonceFromResponse(response);
  }

  Map<String, String> get _headers {
    final h = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'User-Agent': 'QFurnitureApp/1.0 (WooCommerce Store API)',
    };
    if (_cookie != null) h['Cookie'] = _cookie!;
    if (_cartToken != null && _cartToken!.isNotEmpty) {
      h['Cart-Token'] = _cartToken!;
    }
    if (_storeApiNonce != null && _storeApiNonce!.isNotEmpty) {
      h['Nonce'] = _storeApiNonce!;
    }
    return h;
  }

  /// Prime session cookie + nonce before first add-item (many servers reject POST without nonce).
  Future<void> _ensureStoreApiSessionPrimed() async {
    // Prime session cookie + cart token / nonce so POST requests can succeed.
    if ((_cartToken != null && _cartToken!.isNotEmpty) ||
        (_storeApiNonce != null && _storeApiNonce!.isNotEmpty)) {
      return;
    }
    try {
      if (kDebugMode) {
        debugPrint('[StoreCart] priming session nonce via GET /cart ...');
      }
      Future<http.Response> getCart(Uri u) =>
          http.get(u, headers: _headers).timeout(const Duration(seconds: 15));

      // Try both endpoints: some hosts attach the nonce to one but not the other.
      final resCart = await getCart(_cartRoot);
      if (kDebugMode) {
        debugPrint(
          '[StoreCart] prime GET /cart status=${resCart.statusCode} contentType=${resCart.headers['content-type']} bodyLen=${resCart.body.length}',
        );
      }
      await _absorbResponse(resCart);

      if (_storeApiNonce == null || _storeApiNonce!.isEmpty) {
        if (kDebugMode) {
          debugPrint(
            '[StoreCart] no nonce after GET /cart status=${resCart.statusCode}; trying GET /cart/items...',
          );
        }
        final resItems = await getCart(_cartItems);
        if (kDebugMode) {
          debugPrint(
            '[StoreCart] prime GET /cart/items status=${resItems.statusCode} contentType=${resItems.headers['content-type']} bodyLen=${resItems.body.length}',
          );
        }
        await _absorbResponse(resItems);

        if (kDebugMode) {
          debugPrint(
            '[StoreCart] after GET /cart/items status=${resItems.statusCode} noncePresent=${_storeApiNonce != null && _storeApiNonce!.isNotEmpty}',
          );
        }
      } else {
        if (kDebugMode) {
          debugPrint(
            '[StoreCart] nonce present after GET /cart status=${resCart.statusCode} nonceLen=${_storeApiNonce!.length}',
          );
        }
      }
    } catch (_) {}
  }

  void _logCartFailure(String action, http.Response? res) {
    if (!kDebugMode || res == null) return;
    debugPrint(
      '[StoreCart] $action failed: status=${res.statusCode} body=${res.body.length > 800 ? '${res.body.substring(0, 800)}…' : res.body}',
    );
  }

  /// Add item to store cart (creates session; save cookie from response).
  /// Official Store API route is `POST /cart/add-item`; `POST /cart/items` is a fallback.
  Future<bool> addItem(int productId, {int quantity = 1}) async {
    Future<bool> tryPost() async {
      await _ensureStoreApiSessionPrimed();
      if (kDebugMode) {
        debugPrint(
          '[StoreCart] nonce before POST add-item: ${_storeApiNonce == null ? 'null' : '${_storeApiNonce!.substring(0, 8)}…'}',
        );
      }
      final body = jsonEncode({'id': productId, 'quantity': quantity});
      try {
        final res = await http
            .post(
              _cartAddItem,
              headers: _headers,
              body: body,
            )
            .timeout(const Duration(seconds: 15));
        await _absorbResponse(res);
        if (res.statusCode >= 200 && res.statusCode < 300) {
          return true;
        }
        _logCartFailure('POST add-item', res);
      } catch (e) {
        if (kDebugMode) debugPrint('[StoreCart] POST add-item error: $e');
      }
      try {
        final res = await http
            .post(
              _cartItems,
              headers: _headers,
              body: body,
            )
            .timeout(const Duration(seconds: 15));
        await _absorbResponse(res);
        if (res.statusCode >= 200 && res.statusCode < 300) {
          return true;
        }
        _logCartFailure('POST cart/items', res);
        return false;
      } catch (e) {
        if (kDebugMode) debugPrint('[StoreCart] POST cart/items error: $e');
        return false;
      }
    }

    final ok = await tryPost();
    if (ok) return true;
    // Stale nonce after app restart; re-fetch from GET /cart and retry once.
    _storeApiNonce = null;
    return tryPost();
  }

  /// Syncs an entire local cart to the online store via the batch endpoint.
  Future<bool> syncCartToOnline(
      List<({int productId, int quantity})> items) async {
    if (items.isEmpty) return true;
    await _ensureStoreApiSessionPrimed();

    try {
      final requests = items.map((item) {
        return {
          'method': 'POST',
          'path': '/wc/store/v1/cart/add-item',
          'body': {
            'id': item.productId,
            'quantity': item.quantity,
          }
        };
      }).toList();

      final uri = Uri.parse('$_base/batch');
      final res = await http
          .post(
            uri,
            headers: _headers,
            body: jsonEncode({'requests': requests}),
          )
          .timeout(const Duration(seconds: 20));

      if (res.statusCode >= 200 && res.statusCode < 300) {
        await _absorbResponse(res);
        return true;
      }
      _logCartFailure('POST batch', res);
      return false;
    } catch (e) {
      if (kDebugMode) debugPrint('[StoreCart] batch error: $e');
      return false;
    }
  }

  /// GET full cart (Store API) — items, totals, shipping_rates, etc.
  /// [success] is false when the request failed (do not treat as empty cart).
  Future<({bool success, Map<String, dynamic>? data})> fetchFullCart() async {
    try {
      final res = await http.get(_cartRoot, headers: _headers).timeout(
            const Duration(seconds: 15),
          );
      await _absorbResponse(res);
      if (res.statusCode != 200) {
        _logCartFailure('GET cart', res);
        return (success: false, data: null);
      }
      final data = jsonDecode(res.body);
      if (data is Map<String, dynamic>) {
        return (success: true, data: data);
      }
      return (success: false, data: null);
    } catch (_) {
      return (success: false, data: null);
    }
  }

  /// GET cart items (lightweight list for keys / product ids).
  Future<List<({int id, String key, int quantity})>> getItems() async {
    try {
      final res = await http.get(_cartItems, headers: _headers).timeout(
            const Duration(seconds: 10),
          );
      if (res.statusCode != 200) return [];
      await _absorbResponse(res);
      final list = jsonDecode(res.body) as List<dynamic>?;
      if (list == null) return [];
      final items = <({int id, String key, int quantity})>[];
      for (final e in list) {
        final m = e as Map<String, dynamic>?;
        if (m == null) continue;
        final id =
            m['id'] is int ? m['id'] as int : int.tryParse(m['id'].toString());
        final key = m['key'] as String?;
        final quantity = m['quantity'] as int? ?? 1;
        if (id != null && key != null && key.isNotEmpty) {
          items.add((id: id, key: key, quantity: quantity));
        }
      }
      return items;
    } catch (_) {
      return [];
    }
  }

  /// Remove item from store cart (Store API: POST /cart/remove-item).
  Future<bool> removeItem(String key) async {
    if (!hasSession) return false;
    try {
      final uri = Uri.parse('$_base/cart/remove-item').replace(
        queryParameters: {'key': key},
      );
      final res = await http.post(uri, headers: _headers).timeout(
            const Duration(seconds: 10),
          );
      await _absorbResponse(res);
      if (res.statusCode >= 200 && res.statusCode < 300) return true;
      // Some stacks still expose DELETE /cart/items/{key}
      try {
        final legacy = Uri.parse('$_base/cart/items/$key');
        final res2 = await http.delete(legacy, headers: _headers).timeout(
              const Duration(seconds: 10),
            );
        await _absorbResponse(res2);
        return res2.statusCode >= 200 && res2.statusCode < 300;
      } catch (_) {
        return false;
      }
    } catch (_) {
      return false;
    }
  }

  /// Remove item by product id (resolves key from GET items then DELETE).
  Future<bool> removeItemByProductId(int productId) async {
    final items = await getItems();
    final entry = items.where((e) => e.id == productId).firstOrNull;
    if (entry == null) return true;
    return removeItem(entry.key);
  }

  /// Update quantity for a cart item by product id (GET key then PUT).
  Future<bool> updateItemByProductId(int productId, int quantity) async {
    if (quantity <= 0) return removeItemByProductId(productId);
    final items = await getItems();
    final entry = items.where((e) => e.id == productId).firstOrNull;
    if (entry == null) return false;
    return updateItem(entry.key, quantity);
  }

  /// Update quantity (Store API: POST /cart/update-item?key=&quantity=).
  Future<bool> updateItem(String key, int quantity) async {
    if (!hasSession) return false;
    if (quantity <= 0) return removeItem(key);
    try {
      final uri = Uri.parse('$_base/cart/update-item').replace(
        queryParameters: {
          'key': key,
          'quantity': quantity.toString(),
        },
      );
      final res = await http.post(uri, headers: _headers).timeout(
            const Duration(seconds: 10),
          );
      await _absorbResponse(res);
      if (res.statusCode >= 200 && res.statusCode < 300) return true;
      try {
        final legacy =
            Uri.parse('$_base/cart/items/$key').replace(queryParameters: {
          'quantity': quantity.toString(),
        });
        final res2 = await http.put(legacy, headers: _headers).timeout(
              const Duration(seconds: 10),
            );
        await _absorbResponse(res2);
        return res2.statusCode >= 200 && res2.statusCode < 300;
      } catch (_) {
        return false;
      }
    } catch (_) {
      return false;
    }
  }

  /// Remove all items from store cart (DELETE empty cart — legacy; else clear line-by-line).
  Future<bool> clearCart() async {
    if (!hasSession) return true;
    try {
      final items = await getItems();
      for (final e in items) {
        await removeItem(e.key);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> clearSession() async {
    _cookie = null;
    _storeApiNonce = null;
    _cartToken = null;
    await _prefs?.remove('cart_session_cookie');
    await _prefs?.remove('cart_cart_token');
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    for (final e in this) {
      return e;
    }
    return null;
  }
}

String _normalizeCookieName(String name) => name.trim().toLowerCase();

bool _isWooSessionCookieName(String name) =>
    _normalizeCookieName(name).startsWith('wp_woocommerce_session_');

String? _extractWooSessionPair(String? cookie) {
  if (cookie == null || cookie.trim().isEmpty) return null;
  final pairs = cookie
      .split(';')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty);
  for (final p in pairs) {
    final i = p.indexOf('=');
    if (i <= 0) continue;
    final name = p.substring(0, i).trim();
    if (_isWooSessionCookieName(name)) return p;
  }
  return null;
}

String _mergeCookiesPreservingSession({
  required String? existing,
  required String incoming,
}) {
  final incomingTrim = incoming.trim();
  if (incomingTrim.isEmpty) return existing ?? incomingTrim;
  final incomingSession = _extractWooSessionPair(incomingTrim);
  if (incomingSession != null) return incomingTrim;

  final existingSession = _extractWooSessionPair(existing);
  if (existingSession == null) return incomingTrim;
  return '$incomingTrim; $existingSession';
}
