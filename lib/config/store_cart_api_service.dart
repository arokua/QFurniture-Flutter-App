import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, kIsWeb;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'store_config.dart';
import '../services/web_auth_cookie_store.dart';
import '../services/web_session_cache.dart';

/// WooCommerce Store API (wc/store/v1) cart: add, remove, update.
/// Cart is session-based; we persist cookie from first add so remove/update work.
/// Endpoints: POST add-item, GET items, DELETE items/:key, PUT items/:key.
///
/// Note: add-to-cart for checkout is handled via the WebView ?add-to-cart= URL
/// flow, not this service. This service handles session management and
/// direct cart reads/writes for non-checkout flows.
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
  /// JWT Bearer token for server-side auth (bypasses Cart-Token/Nonce requirement on the server).
  String? _jwtToken;

  /// Fallback JWT set by AuthService at login/restore time.
  /// Avoids a circular import — AuthService calls [setJwtFallback] instead of being imported here.
  static String? _jwtFallback;

  /// Called by AuthService after login/restore to provide a fallback JWT.
  static void setJwtFallback(String? token) {
    _jwtFallback = token?.trim().isEmpty == true ? null : token?.trim();
  }

  SharedPreferences? _prefs;

  /// 500-error cooldown: tracks last 500 timestamp to avoid hammering a broken endpoint.
  DateTime? _lastCart500At;
  static const _cart500CooldownSeconds = 10; // Reduced: 30s was masking real issues

  /// True when the server recently returned 500 — callers should skip and use local state.
  bool get isTemporarilyUnavailable {
    if (_lastCart500At == null) return false;
    return DateTime.now().difference(_lastCart500At!).inSeconds <
        _cart500CooldownSeconds;
  }

  void _record500() {
    _lastCart500At = DateTime.now();
    if (kDebugMode) {
      debugPrint(
        '[StoreCart] 500 recorded — cooling down for ${_cart500CooldownSeconds}s',
      );
    }
  }

  void _clearCooldown() {
    _lastCart500At = null;
  }

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _cookie = _prefs?.getString('cart_session_cookie');
    // Nonce is not persisted: stale nonces cause POST /cart/add-item to fail after restarts.
    _cartToken = _prefs?.getString('cart_cart_token');
  }

  /// Set the JWT token so authenticated requests can bypass Store API nonce/token requirement.
  void setJwtToken(String? token) {
    _jwtToken = token?.trim().isEmpty == true ? null : token?.trim();
  }

  /// True when we have enough info to call the Store API for this cart.
  /// Cart-Token can replace cookies for headless cart sessions.
  bool get hasSession =>
      (_cookie != null && _cookie!.isNotEmpty) ||
      (_cartToken != null && _cartToken!.isNotEmpty);

  /// Expose the current session cookie for WebView injection.
  String? get cookie => _cookie;

  /// Expose the current WooCommerce cart token for headless cart usage.
  String? get cartToken => _cartToken;

  /// Set cookie from external source (e.g. WebView).
  Future<void> setCookie(String cookie) async {
    _cookie = _mergeCookiesPreservingSession(existing: _cookie, incoming: cookie);
    await _prefs?.setString('cart_session_cookie', _cookie ?? cookie);
  }

  Future<void> setCookieFromResponse(http.Response response) async {
    final setCookie = response.headers['set-cookie'];
    if (setCookie != null && setCookie.isNotEmpty) {
      final incoming =
          setCookie.split(',').map((s) => s.trim().split(';').first).join('; ');
      _cookie = _mergeCookiesPreservingSession(
        existing: _cookie,
        incoming: incoming,
      );
      await _prefs?.setString('cart_session_cookie', _cookie ?? incoming);
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

  /// Public: absorb nonce/cart-token/cookie from any HTTP response.
  /// Call this after your own GET /cart so the service has the session
  /// headers for subsequent POST add-item/remove-item calls.
  Future<void> absorbResponseHeaders(http.Response response) =>
      _absorbResponse(response);

  /// Force-create/refresh Woo Store API session after JWT login.
  /// Calls your JWT->cookie bridge, persists WP auth cookies, then primes cart.
  Future<bool> bootstrapSessionFromJwt(String? jwt) async {
    final token = jwt?.trim();
    if (token == null || token.isEmpty) return false;
    await _runJwtMobileSessionBridge(token: token, source: 'flutter_app_login');
    try {
      final cart = await fetchFullCart();
      if (cart.success && cart.data != null) {
        await absorbCartSessionFromCartJson(cart.data!);
      }
      return hasSession;
    } catch (_) {
      return hasSession;
    }
  }

  /// Refresh persisted WP auth cookies from the JWT bridge (no WebView navigation).
  Future<bool> persistWebAuthCookiesFromBridge() async {
    if (kIsWeb) return false;
    final token = (_jwtToken?.isNotEmpty == true) ? _jwtToken! : _jwtFallback;
    if (token == null || token.isEmpty) return false;
    return _runJwtMobileSessionBridge(
      token: token,
      source: 'flutter_app_persist',
    );
  }

  /// POST `/wp-json/qtoys/v1/mobile-session` and mirror Set-Cookie into the
  /// WebView jar + app cart session. Returns true when WP auth cookies arrived.
  Future<bool> establishWebSessionForWebView(
    WebViewCookieManager cookieManager,
  ) async {
    if (kIsWeb) return false;
    final token = (_jwtToken?.isNotEmpty == true) ? _jwtToken! : _jwtFallback;
    if (token == null || token.isEmpty) return false;
    return _runJwtMobileSessionBridge(
      token: token,
      source: 'flutter_app_webview',
      cookieManager: cookieManager,
    );
  }

  Future<bool> _runJwtMobileSessionBridge({
    required String token,
    required String source,
    WebViewCookieManager? cookieManager,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse(jwtCookieBridgeUrl));
      req.headers.set('Authorization', 'Bearer $token');
      req.headers.set('Accept', 'application/json');
      req.headers.set('Content-Type', 'application/json');
      req.headers.set('User-Agent', kAppUserAgent);
      req.write(jsonEncode({'source': source}));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        if (kDebugMode) {
          debugPrint(
            '[StoreCart] mobile-session HTTP ${resp.statusCode} '
            'body=${body.length > 120 ? '${body.substring(0, 120)}…' : body}',
          );
        }
        return false;
      }

      await WebAuthCookieStore.saveFromHttpHeaders(resp.headers);
      await _absorbSetCookieHeaders(resp.headers);

      var hadAuth = _headersContainAuthCookie(resp.headers);
      if (cookieManager != null) {
        final mirrored = await _mirrorSetCookiesToWebView(
          resp.headers,
          cookieManager,
        );
        hadAuth = hadAuth || mirrored;
      }
      if (hadAuth) {
        await WebSessionCache.markValid();
      }
      if (kDebugMode) {
        debugPrint('[StoreCart] mobile-session ok authCookies=$hadAuth');
      }
      return hadAuth;
    } catch (e) {
      if (kDebugMode) debugPrint('[StoreCart] mobile-session error: $e');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  bool _headersContainAuthCookie(HttpHeaders headers) {
    var found = false;
    headers.forEach((name, values) {
      if (name.toLowerCase() != 'set-cookie') return;
      for (final header in values) {
        final first = header.split(';').first.trim();
        final eq = first.indexOf('=');
        if (eq <= 0) continue;
        final cookieName = first.substring(0, eq).trim().toLowerCase();
        if (cookieName.startsWith('wordpress_logged_in') ||
            cookieName.startsWith('wordpress_sec_')) {
          found = true;
        }
      }
    });
    return found;
  }

  Future<bool> _mirrorSetCookiesToWebView(
    HttpHeaders headers,
    WebViewCookieManager cookieManager,
  ) async {
    final domain = Uri.parse(kStoreBaseUrl).host;
    var hadAuth = false;
    headers.forEach((name, values) {
      if (name.toLowerCase() != 'set-cookie') return;
      for (final header in values) {
        final parts = header.split(';').map((s) => s.trim()).toList();
        if (parts.isEmpty) continue;
        final nv = parts.first.split('=');
        if (nv.length < 2) continue;
        final cookieName = nv[0].trim();
        final cookieValue = nv.sublist(1).join('=').trim();
        if (cookieName.isEmpty) continue;
        final lower = cookieName.toLowerCase();
        if (lower.startsWith('wordpress_logged_in') ||
            lower.startsWith('wordpress_sec_')) {
          hadAuth = true;
        }
        var path = '/';
        for (final attr in parts.skip(1)) {
          if (attr.toLowerCase().startsWith('path=')) {
            path = attr.substring(5).trim();
          }
        }
        cookieManager
            .setCookie(
              WebViewCookie(
                name: cookieName,
                value: cookieValue,
                domain: domain,
                path: path,
              ),
            )
            .catchError((_) {});
      }
    });
    return hadAuth;
  }

  Future<void> _absorbSetCookieHeaders(HttpHeaders headers) async {
    final pairs = <String>[];
    headers.forEach((name, values) {
      if (name.toLowerCase() != 'set-cookie') return;
      for (final header in values) {
        final first = header.split(';').first.trim();
        if (first.isNotEmpty) pairs.add(first);
      }
    });
    if (pairs.isEmpty) return;
    final merged = pairs.join('; ');
    _cookie = _mergeCookiesPreservingSession(
      existing: _cookie,
      incoming: merged,
    );
    await _prefs?.setString('cart_session_cookie', _cookie ?? merged);
  }

  /// Persist [Cart-Token] from a WooCommerce Store API `GET /cart` JSON body (e.g. WebView).
  /// Keeps the app's HTTP client on the same cart session as the browser.
  Future<void> absorbCartSessionFromCartJson(Map<String, dynamic> json) async {
    final token = _extractCartTokenFromCartJson(json);
    if (token != null && token.isNotEmpty) {
      _cartToken = token;
      await _prefs?.setString('cart_cart_token', token);
      if (kDebugMode) {
        debugPrint('[StoreCart] absorbed Cart-Token from cart JSON (len=${token.length})');
      }
    }
  }

  /// WooCommerce may expose the token at root or under `extensions`.
  String? _extractCartTokenFromCartJson(Map<String, dynamic> json) {
    final root = json['token'];
    if (root is String && root.trim().isNotEmpty) return root.trim();
    final ext = json['extensions'];
    if (ext is Map<String, dynamic>) {
      final woo = ext['woocommerce'];
      if (woo is Map<String, dynamic>) {
        for (final k in ['cart_token', 'token', 'cartToken']) {
          final v = woo[k];
          if (v is String && v.trim().isNotEmpty) return v.trim();
        }
      }
    }
    return null;
  }

  /// Append a cache-buster + identity query param so the request bypasses the
  /// server FastCGI / Cloudflare cache. The /cart endpoint is cached (HIT),
  /// which otherwise returns a stale empty guest cart regardless of Cart-Token.
  static Uri bustCache(Uri u) => u.replace(queryParameters: {
        ...u.queryParameters,
        '_cb': DateTime.now().microsecondsSinceEpoch.toString(),
      });

  /// Headers for GET requests — no Content-Type (avoids Cerber/WP rejecting GETs with body-type header).
  Map<String, String> get _getHeaders {
    final h = <String, String>{
      'Accept': 'application/json',
      'User-Agent': kAppUserAgent,
      // Defeat FastCGI/Cloudflare caching of the cart endpoint.
      'Cache-Control': 'no-cache, no-store, must-revalidate',
      'Pragma': 'no-cache',
    };
    if (_cookie != null && _cookie!.isNotEmpty) h['Cookie'] = _cookie!;
    if (_cartToken != null && _cartToken!.isNotEmpty) h['Cart-Token'] = _cartToken!;
    if (_storeApiNonce != null && _storeApiNonce!.isNotEmpty) h['Nonce'] = _storeApiNonce!;
    // Prefer explicitly set token; fall back to AuthService-provided fallback.
    final jwt = (_jwtToken?.isNotEmpty == true) ? _jwtToken! : _jwtFallback;
    if (jwt != null && jwt.isNotEmpty) h['Authorization'] = 'Bearer $jwt';
    return h;
  }

  /// Headers for POST/PUT/DELETE requests — includes Content-Type.
  Map<String, String> get _postHeaders {
    final h = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'User-Agent': kAppUserAgent,
    };
    if (_cookie != null && _cookie!.isNotEmpty) h['Cookie'] = _cookie!;
    if (_cartToken != null && _cartToken!.isNotEmpty) h['Cart-Token'] = _cartToken!;
    if (_storeApiNonce != null && _storeApiNonce!.isNotEmpty) h['Nonce'] = _storeApiNonce!;
    final jwt = (_jwtToken?.isNotEmpty == true) ? _jwtToken! : _jwtFallback;
    if (jwt != null && jwt.isNotEmpty) h['Authorization'] = 'Bearer $jwt';
    return h;
  }

  /// Prime session cookie + nonce before first add-item (many servers reject POST without nonce).
  Future<void> _ensureStoreApiSessionPrimed() async {
    if ((_cartToken != null && _cartToken!.isNotEmpty) ||
        (_storeApiNonce != null && _storeApiNonce!.isNotEmpty)) {
      return;
    }
    try {
      if (kDebugMode) debugPrint('[StoreCart] priming session via GET /cart ...');

      final resCart = await http
          .get(bustCache(_cartRoot), headers: _getHeaders)
          .timeout(const Duration(seconds: 15));
      if (kDebugMode) {
        debugPrint('[StoreCart] prime GET /cart status=${resCart.statusCode} bodyLen=${resCart.body.length}');
      }
      await _absorbResponse(resCart);

      if (_storeApiNonce == null || _storeApiNonce!.isEmpty) {
        final resItems = await http
            .get(bustCache(_cartItems), headers: _getHeaders)
            .timeout(const Duration(seconds: 15));
        if (kDebugMode) {
          debugPrint('[StoreCart] prime GET /cart/items status=${resItems.statusCode}');
        }
        await _absorbResponse(resItems);
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
      final body = jsonEncode({'id': productId, 'quantity': quantity});
      try {
        final res = await http
            .post(_cartAddItem, headers: _postHeaders, body: body)
            .timeout(const Duration(seconds: 15));
        await _absorbResponse(res);
        if (res.statusCode >= 200 && res.statusCode < 300) return true;
        _logCartFailure('POST add-item', res);
      } catch (e) {
        if (kDebugMode) debugPrint('[StoreCart] POST add-item error: $e');
      }
      try {
        final res = await http
            .post(_cartItems, headers: _postHeaders, body: body)
            .timeout(const Duration(seconds: 15));
        await _absorbResponse(res);
        if (res.statusCode >= 200 && res.statusCode < 300) return true;
        _logCartFailure('POST cart/items', res);
        return false;
      } catch (e) {
        if (kDebugMode) debugPrint('[StoreCart] POST cart/items error: $e');
        return false;
      }
    }

    final ok = await tryPost();
    if (ok) return true;
    _storeApiNonce = null;
    return tryPost();
  }

  /// Drives one product to an **absolute** [targetQuantity].
  ///
  /// This is the only cart mutation the coordinator dispatches, because it is
  /// safe to replay. `POST /cart/add-item` *increments* server-side, so a
  /// request that succeeded but timed out client-side would double the line on
  /// retry. Resolving to `update-item` (idempotent) whenever a line key is
  /// known, and verifying after a blind add, removes that whole failure class.
  ///
  /// [knownKey] is the Store API `items[].key` from the last confirmed cart.
  /// When absent, the key is resolved from the server before deciding.
  Future<bool> updateOrAddByProductId(
    int productId, {
    required int targetQuantity,
    String? knownKey,
  }) async {
    if (!hasSession) {
      // No session yet: nothing to update, so an add is the only option and
      // cannot double anything.
      if (targetQuantity <= 0) return true;
      return addItemOnce(productId, quantity: targetQuantity);
    }

    var key = knownKey;
    if (key == null || key.isEmpty) {
      final items = await getItems();
      key = items.where((e) => e.id == productId).firstOrNull?.key;
    }

    if (targetQuantity <= 0) {
      // Already absent is the desired end state, so report success.
      if (key == null || key.isEmpty) return true;
      return removeItem(key);
    }

    if (key != null && key.isNotEmpty) {
      return updateItem(key, targetQuantity);
    }

    // Not in the cart yet. Add once, then verify rather than blind-retrying:
    // an ambiguous timeout may already have applied server-side.
    final added = await addItemOnce(productId, quantity: targetQuantity);
    final items = await getItems();
    final entry = items.where((e) => e.id == productId).firstOrNull;
    if (entry == null) return added;
    if (entry.quantity == targetQuantity) return true;
    // The add landed with the wrong quantity (e.g. a retry stacked on top).
    // Converge with an idempotent update instead of adding again.
    return updateItem(entry.key, targetQuantity);
  }

  /// Single `add-item` attempt with the endpoint fallback but **no** retry.
  ///
  /// [addItem] retries the whole pair after clearing the nonce, which can turn
  /// one logical add into four POSTs against an incrementing endpoint.
  Future<bool> addItemOnce(int productId, {int quantity = 1}) async {
    await _ensureStoreApiSessionPrimed();
    final body = jsonEncode({'id': productId, 'quantity': quantity});
    try {
      final res = await http
          .post(_cartAddItem, headers: _postHeaders, body: body)
          .timeout(const Duration(seconds: 15));
      await _absorbResponse(res);
      if (res.statusCode >= 200 && res.statusCode < 300) return true;
      _logCartFailure('POST add-item', res);
    } catch (e) {
      if (kDebugMode) debugPrint('[StoreCart] POST add-item error: $e');
    }
    try {
      final res = await http
          .post(_cartItems, headers: _postHeaders, body: body)
          .timeout(const Duration(seconds: 15));
      await _absorbResponse(res);
      if (res.statusCode >= 200 && res.statusCode < 300) return true;
      _logCartFailure('POST cart/items', res);
      return false;
    } catch (e) {
      if (kDebugMode) debugPrint('[StoreCart] POST cart/items error: $e');
      return false;
    }
  }

  // Note: syncCartToOnline (batch endpoint) has been removed.
  // Cart items are now synced to WooCommerce via the WebView ?add-to-cart= URL
  // queue in StoreWebViewScreen, which is more reliable and avoids
  // the audit-checkout.php session header requirements for batch requests.


  /// GET full cart (Store API) — items, totals, shipping_rates, etc.
  /// [success] is false when the request failed (do not treat as empty cart).
  Future<({bool success, Map<String, dynamic>? data})> fetchFullCart() async {
    if (isTemporarilyUnavailable) {
      if (kDebugMode) debugPrint('[StoreCart] skipping GET cart — in 500 cooldown');
      return (success: false, data: null);
    }
    try {
      final cartUrl = bustCache(_cartRoot);
      if (kDebugMode) debugPrint('[StoreCart] GET $cartUrl');
      // Use _getHeaders (no Content-Type) — sending Content-Type on a GET
      // was causing Cerber/audit-checkout.php to return 500.
      final res = await http
          .get(cartUrl, headers: _getHeaders)
          .timeout(const Duration(seconds: 15));
      await _absorbResponse(res);
      if (res.statusCode == 500) {
        _record500();
        if (kDebugMode) {
          debugPrint('[StoreCart] GET cart → 500. body=${res.body.length > 300 ? res.body.substring(0, 300) : res.body}');
        }
        return (success: false, data: null);
      }
      if (res.statusCode != 200) {
        _logCartFailure('GET cart', res);
        return (success: false, data: null);
      }
      _clearCooldown();
      if (kDebugMode) debugPrint('[StoreCart] GET cart → ${res.statusCode} len=${res.body.length}');
      final data = jsonDecode(res.body);
      if (data is Map<String, dynamic>) return (success: true, data: data);
      return (success: false, data: null);
    } catch (_) {
      return (success: false, data: null);
    }
  }

  /// GET cart items (lightweight list for keys / product ids).
  Future<List<({int id, String key, int quantity})>> getItems() async {
    try {
      final res = await http
          .get(bustCache(_cartItems), headers: _getHeaders)
          .timeout(const Duration(seconds: 10));
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
      final uri = Uri.parse('$_base/cart/remove-item')
          .replace(queryParameters: {'key': key});
      final res = await http
          .post(uri, headers: _postHeaders)
          .timeout(const Duration(seconds: 10));
      await _absorbResponse(res);
      if (res.statusCode >= 200 && res.statusCode < 300) return true;
      try {
        final legacy = Uri.parse('$_base/cart/items/$key');
        final res2 = await http
            .delete(legacy, headers: _postHeaders)
            .timeout(const Duration(seconds: 10));
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
      final uri = Uri.parse('$_base/cart/update-item')
          .replace(queryParameters: {'key': key, 'quantity': quantity.toString()});
      final res = await http
          .post(uri, headers: _postHeaders)
          .timeout(const Duration(seconds: 10));
      await _absorbResponse(res);
      if (res.statusCode >= 200 && res.statusCode < 300) return true;
      try {
        final legacy = Uri.parse('$_base/cart/items/$key')
            .replace(queryParameters: {'quantity': quantity.toString()});
        final res2 = await http
            .put(legacy, headers: _postHeaders)
            .timeout(const Duration(seconds: 10));
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

  /// Clears cart session + persisted WebView WP auth cookies (sign-out).
  Future<void> clearAllSessions() async {
    await clearSession();
    await WebAuthCookieStore.clear();
  }

  /// Clears platform WebView cookie jar so Woo auth/cart does not survive app logout.
  Future<void> clearEmbeddedWebViewCookies() async {
    if (kIsWeb) return;
    try {
      final cm = WebViewCookieManager();
      await cm.clearCookies();
    } catch (_) {
      // Best-effort
    }
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
