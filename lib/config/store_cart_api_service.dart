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
  static Uri get _cartRoot => Uri.parse('$_base/cart');

  String? _cookie;
  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _cookie = _prefs?.getString('cart_session_cookie');
  }

  bool get hasSession => _cookie != null && _cookie!.isNotEmpty;

  /// Expose the current session cookie for WebView injection.
  String? get cookie => _cookie;

  /// Set cookie from external source (e.g. WebView).
  Future<void> setCookie(String cookie) async {
    _cookie = cookie;
    await _prefs?.setString('cart_session_cookie', cookie);
  }

  Future<void> setCookieFromResponse(http.Response response) async {
    final setCookie = response.headers['set-cookie'];
    if (setCookie != null && setCookie.isNotEmpty) {
      _cookie =
          setCookie.split(',').map((s) => s.trim().split(';').first).join('; ');
      await _prefs?.setString('cart_session_cookie', _cookie!);
    }
  }

  Map<String, String> get _headers {
    final h = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (_cookie != null) h['Cookie'] = _cookie!;
    return h;
  }

  /// Add item to store cart (creates session; save cookie from response).
  Future<bool> addItem(int productId, {int quantity = 1}) async {
    try {
      final res = await http
          .post(
            _cartItems,
            headers: _headers,
            body: jsonEncode({
              'id': productId,
              'quantity': quantity,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        await setCookieFromResponse(res);
        return true;
      }
      // If error, maybe capture error message for debugging
      await setCookieFromResponse(res);
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Syncs an entire local cart to the online store via the batch endpoint.
  Future<bool> syncCartToOnline(
      List<({int productId, int quantity})> items) async {
    if (items.isEmpty) return true;

    try {
      final requests = items.map((item) {
        return {
          'method': 'POST',
          'path': '/wc/store/v1/cart/items',
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
        await setCookieFromResponse(res);
        return true;
      }
      return false;
    } catch (_) {
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
      await setCookieFromResponse(res);
      if (res.statusCode != 200) {
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
      await setCookieFromResponse(res);
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
      await setCookieFromResponse(res);
      if (res.statusCode >= 200 && res.statusCode < 300) return true;
      // Some stacks still expose DELETE /cart/items/{key}
      try {
        final legacy = Uri.parse('$_base/cart/items/$key');
        final res2 = await http.delete(legacy, headers: _headers).timeout(
              const Duration(seconds: 10),
            );
        await setCookieFromResponse(res2);
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
      await setCookieFromResponse(res);
      if (res.statusCode >= 200 && res.statusCode < 300) return true;
      try {
        final legacy =
            Uri.parse('$_base/cart/items/$key').replace(queryParameters: {
          'quantity': quantity.toString(),
        });
        final res2 = await http.put(legacy, headers: _headers).timeout(
              const Duration(seconds: 10),
            );
        await setCookieFromResponse(res2);
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
    await _prefs?.remove('cart_session_cookie');
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    for (final e in this) return e;
    return null;
  }
}
