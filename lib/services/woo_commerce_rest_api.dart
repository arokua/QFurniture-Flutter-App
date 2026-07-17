import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:http/http.dart' as http;

import '../config/store_cart_api_service.dart';
import '../config/store_config.dart';
import '../features/cart/data/store_cart_snapshot.dart';
import '../features/cart/domain/role_cart_pricing.dart';
import '../features/orders/domain/woo_order_summary.dart';

/// WooCommerce REST API (`/wp-json/wc/v3/...`) with Basic-auth + JWT fallbacks.
class WooCommerceRestApi {
  WooCommerceRestApi._();
  static final WooCommerceRestApi instance = WooCommerceRestApi._();

  static String get _v3Base => '$kStoreBaseUrl/wp-json/wc/v3';
  static String get _qtoysOrders => '$kStoreBaseUrl/wp-json/qtoys/v1/my-orders';

  static String? get _basicAuthHeader {
    if (kWooKey.isEmpty || kWooSecret.isEmpty) return null;
    final token = base64Encode(utf8.encode('$kWooKey:$kWooSecret'));
    return 'Basic $token';
  }

  Map<String, String> _jwtHeaders(String jwt) => {
        'Authorization': 'Bearer $jwt',
        'Accept': 'application/json',
        'User-Agent': kAppUserAgent,
      };

  Map<String, String> _basicHeaders() => {
        'Authorization': _basicAuthHeader!,
        'Accept': 'application/json',
        'User-Agent': kAppUserAgent,
      };

  Map<String, String> _jsonPostHeaders(String jwt) => {
        ..._jwtHeaders(jwt),
        'Content-Type': 'application/json',
      };

  /// GET with Basic auth first (reliable for wc/v3), then JWT Bearer.
  Future<http.Response> _getV3(
    String path, {
    Map<String, String>? query,
    required String jwt,
  }) async {
    final uri = StoreCartApiService.bustCache(
      Uri.parse('$_v3Base$path').replace(queryParameters: query),
    );
    final getHeaders = {
      'Accept': 'application/json',
      'User-Agent': kAppUserAgent,
      'Cache-Control': 'no-cache, no-store, must-revalidate',
      'Pragma': 'no-cache',
    };

    if (_basicAuthHeader != null) {
      final res = await http
          .get(uri, headers: {...getHeaders, 'Authorization': _basicAuthHeader!})
          .timeout(const Duration(seconds: 20));
      if (kDebugMode) {
        debugPrint('[WooRest] Basic GET $uri → ${res.statusCode}');
      }
      if (res.statusCode == 200) return res;
    }

    final res = await http
        .get(uri, headers: {...getHeaders, 'Authorization': 'Bearer $jwt'})
        .timeout(const Duration(seconds: 20));
    if (kDebugMode) {
      debugPrint('[WooRest] JWT GET $uri → ${res.statusCode}');
      if (res.statusCode != 200) {
        debugPrint(
          '[WooRest] body: ${res.body.length > 400 ? res.body.substring(0, 400) : res.body}',
        );
      }
    }
    return res;
  }

  /// POST with Basic auth first (order creation needs write permission), then JWT.
  Future<http.Response> _postV3({
    required String path,
    required String jwt,
    required Map<String, dynamic> body,
  }) async {
    final uri = Uri.parse('$_v3Base$path');
    final encoded = jsonEncode(body);

    if (_basicAuthHeader != null) {
      final res = await http
          .post(
            uri,
            headers: {..._basicHeaders(), 'Content-Type': 'application/json'},
            body: encoded,
          )
          .timeout(const Duration(seconds: 30));
      if (kDebugMode) {
        debugPrint('[WooRest] Basic POST $uri → ${res.statusCode}');
      }
      if (res.statusCode == 201 || res.statusCode == 200) return res;
    }

    final res = await http
        .post(
          uri,
          headers: _jsonPostHeaders(jwt),
          body: encoded,
        )
        .timeout(const Duration(seconds: 30));
    if (kDebugMode) {
      debugPrint('[WooRest] JWT POST $uri → ${res.statusCode}');
      if (res.statusCode != 201 && res.statusCode != 200) {
        debugPrint(
          '[WooRest] body: ${res.body.length > 400 ? res.body.substring(0, 400) : res.body}',
        );
      }
    }
    return res;
  }

  List<WooOrderSummary> _parseOrderList(dynamic decoded) {
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(WooOrderSummary.fromJson)
        .toList();
  }

  /// JWT-only custom route (qtoys plugin) — lists orders for the signed-in user.
  Future<({List<WooOrderSummary> orders, bool reached})> fetchOrdersViaQtoysJwt(
    String jwt,
  ) async {
    final uri = StoreCartApiService.bustCache(Uri.parse(_qtoysOrders));
    try {
      final res = await http
          .get(uri, headers: _jwtHeaders(jwt))
          .timeout(const Duration(seconds: 20));
      if (kDebugMode) {
        debugPrint('[WooRest] GET qtoys/my-orders → ${res.statusCode}');
        if (res.statusCode != 200) {
          debugPrint(
            '[WooRest] qtoys body: ${res.body.length > 400 ? res.body.substring(0, 400) : res.body}',
          );
        }
      }
      if (res.statusCode != 200) {
        return (orders: const <WooOrderSummary>[], reached: false);
      }
      final decoded = jsonDecode(res.body);
      if (decoded is Map && decoded['orders'] is List) {
        return (
          orders: _parseOrderList(decoded['orders']),
          reached: true,
        );
      }
      return (orders: _parseOrderList(decoded), reached: true);
    } catch (e) {
      if (kDebugMode) debugPrint('[WooRest] qtoys/my-orders error: $e');
      return (orders: const <WooOrderSummary>[], reached: false);
    }
  }

  List<WooOrderSummary> _sortOrdersNewestFirst(List<WooOrderSummary> orders) {
    final copy = List<WooOrderSummary>.from(orders);
    copy.sort((a, b) => b.dateCreated.compareTo(a.dateCreated));
    return copy;
  }

  void _mergeOrders(
    List<WooOrderSummary> into,
    Set<int> seen,
    List<WooOrderSummary> from,
  ) {
    for (final o in from) {
      if (o.id <= 0 || seen.contains(o.id)) continue;
      seen.add(o.id);
      into.add(o);
    }
  }

  Future<int?> _lookupCustomerIdByEmail(String email, {required String jwt}) async {
    final res = await _getV3(
      '/customers',
      query: {'email': email, 'role': 'all'},
      jwt: jwt,
    );
    if (res.statusCode != 200) return null;
    final body = jsonDecode(res.body);
    if (body is List && body.isNotEmpty) {
      final id = (body.first as Map<String, dynamic>)['id'];
      return id is int ? id : int.tryParse('$id');
    }
    if (body is Map<String, dynamic> && body['id'] != null) {
      final id = body['id'];
      return id is int ? id : int.tryParse('$id');
    }
    return null;
  }

  /// Orders for the signed-in user — merges qtoys JWT route + wc/v3 lookups.
  Future<List<WooOrderSummary>> fetchOrdersForUser({
    required String jwt,
    int? customerId,
    int? wpUserId,
    String? customerEmail,
    int perPage = 25,
  }) async {
    final seen = <int>{};
    final merged = <WooOrderSummary>[];

    final qtoys = await fetchOrdersViaQtoysJwt(jwt);
    _mergeOrders(merged, seen, qtoys.orders);
    if (kDebugMode) {
      debugPrint(
        '[WooRest] fetchOrdersForUser qtoys reached=${qtoys.reached} '
        'count=${qtoys.orders.length}',
      );
    }

    final queryBase = {
      'per_page': '$perPage',
      'orderby': 'date',
      'order': 'desc',
      'status': 'any',
    };

    final customerIds = <int>{};
    if (customerId != null && customerId > 0) customerIds.add(customerId);
    if (wpUserId != null && wpUserId > 0) customerIds.add(wpUserId);

    final email = customerEmail?.trim();
    if (email != null && email.contains('@')) {
      final fromEmail = await _lookupCustomerIdByEmail(email, jwt: jwt);
      if (fromEmail != null && fromEmail > 0) customerIds.add(fromEmail);
    }

    for (final cid in customerIds) {
      final res = await _getV3(
        '/orders',
        query: {...queryBase, 'customer': '$cid'},
        jwt: jwt,
      );
      if (res.statusCode == 200) {
        _mergeOrders(merged, seen, _parseOrderList(jsonDecode(res.body)));
        if (kDebugMode) {
          debugPrint('[WooRest] wc/v3 customer=$cid → ${merged.length} total');
        }
      }
    }

    if (merged.isEmpty && email != null && email.contains('@')) {
      final res = await _getV3(
        '/orders',
        query: {...queryBase, 'search': email},
        jwt: jwt,
      );
      if (res.statusCode == 200) {
        _mergeOrders(merged, seen, _parseOrderList(jsonDecode(res.body)));
        if (kDebugMode) {
          debugPrint('[WooRest] wc/v3 search email → ${merged.length} total');
        }
      }
    }

    if (merged.isEmpty && kDebugMode) {
      debugPrint(
        '[WooRest] fetchOrdersForUser: empty — customerIds=$customerIds '
        'email=$email basicKeys=${_basicAuthHeader != null}',
      );
    }

    return _sortOrdersNewestFirst(merged);
  }

  /// Orders placed by this customer (newest first).
  Future<List<WooOrderSummary>> fetchCustomerOrders({
    required String jwt,
    int? customerId,
    String? customerEmail,
    int perPage = 25,
    bool skipQtoys = false,
  }) async {
    return fetchOrdersForUser(
      jwt: jwt,
      customerId: customerId,
      customerEmail: customerEmail,
      perPage: perPage,
    );
  }

  /// True if the customer has at least one completed order (MOQ “returning” wholesale rule).
  Future<bool> customerHasCompletedOrder({
    required String jwt,
    required int customerId,
  }) async {
    for (final status in ['completed', 'processing', 'on-hold']) {
      final res = await _getV3(
        '/orders',
        query: {
          'customer': '$customerId',
          'per_page': '1',
          'status': status,
        },
        jwt: jwt,
      );
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is List && decoded.isNotEmpty) return true;
      }
    }
    return false;
  }

  /// Single order (includes `line_items`).
  Future<WooOrderSummary?> fetchOrderById({
    required String jwt,
    required int orderId,
    required int customerId,
  }) async {
    final res = await _getV3('/orders/$orderId', jwt: jwt);
    if (res.statusCode != 200) return null;
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) return null;
    final o = WooOrderSummary.fromJson(decoded);
    final cid = o.customerId;
    if (cid != null && cid != customerId) return null;
    return o;
  }

  /// Creates a pending wholesale order (bank deposit / phone credit card).
  Future<({WooOrderSummary? order, String? error})> createWholesaleOrder({
    required String jwt,
    required int customerId,
    required List<({int productId, int quantity})> lineItems,
    required String paymentMethod,
    required String paymentMethodTitle,
    String? billingEmail,
    String? accountType,
    List<Map<String, String>>? orderMeta,
    List<RoleOrderLinePrice>? roleLinePrices,
  }) async {
    if (lineItems.isEmpty) {
      return (order: null, error: 'Cart is empty.');
    }

    final rolePriceById = <int, RoleOrderLinePrice>{
      if (roleLinePrices != null)
        for (final p in roleLinePrices) p.productId: p,
    };

    final linePayload = <Map<String, dynamic>>[];
    var orderSubtotal = 0.0;
    for (final e in lineItems) {
      final row = <String, dynamic>{
        'product_id': e.productId,
        'quantity': e.quantity,
      };
      final priced = rolePriceById[e.productId];
      if (priced != null) {
        row['subtotal'] = priced.lineTotal;
        row['total'] = priced.lineTotal;
        orderSubtotal += double.tryParse(priced.lineTotal) ?? 0;
      }
      linePayload.add(row);
    }

    final orderSubtotalStr =
        orderSubtotal > 0 ? orderSubtotal.toStringAsFixed(2) : null;

    final meta = <Map<String, dynamic>>[
      if (orderMeta != null)
        ...orderMeta.map((e) => {'key': e['key'], 'value': e['value']}),
    ];
    if (!meta.any((m) => m['key'] == 'account_type') &&
        accountType != null &&
        accountType.isNotEmpty) {
      meta.add({'key': 'account_type', 'value': accountType});
    }

    final payload = <String, dynamic>{
      'customer_id': customerId,
      'payment_method': paymentMethod,
      'payment_method_title': paymentMethodTitle,
      'set_paid': false,
      'status': 'on-hold',
      'created_via': 'qtoys-mobile-app',
      'line_items': linePayload,
      if (orderSubtotalStr != null) ...{
        'subtotal': orderSubtotalStr,
        'total': orderSubtotalStr,
      },
      if (meta.isNotEmpty) 'meta_data': meta,
      if (billingEmail != null &&
          billingEmail.trim().isNotEmpty &&
          billingEmail.contains('@'))
        'billing': {'email': billingEmail.trim()},
    };

    try {
      final res = await _postV3(
        path: '/orders',
        jwt: jwt,
        body: payload,
      );

      if (res.statusCode != 201 && res.statusCode != 200) {
        var msg = 'Order could not be created (${res.statusCode}).';
        try {
          final decoded = jsonDecode(res.body);
          if (decoded is Map && decoded['message'] != null) {
            msg = decoded['message'].toString();
          }
        } catch (_) {}
        if (kDebugMode) {
          debugPrint('[WooRest] createWholesaleOrder failed: $msg');
        }
        return (order: null, error: msg);
      }

      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) {
        return (order: null, error: 'Unexpected response from store.');
      }
      final order = WooOrderSummary.fromJson(decoded);
      if (kDebugMode) {
        debugPrint(
          '[WooRest] order created id=${order.id} number=${order.number} '
          'customer=${order.customerId}',
        );
      }
      return (order: order, error: null);
    } catch (e, st) {
      if (kDebugMode) debugPrint('[WooRest] createWholesaleOrder error: $e\n$st');
      return (order: null, error: 'Network error creating order.');
    }
  }
}
