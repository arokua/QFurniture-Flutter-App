import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:http/http.dart' as http;

import '../config/store_config.dart';
import '../features/orders/domain/woo_order_summary.dart';

/// WooCommerce REST API (`/wp-json/wc/v3/...`) using JWT or Basic auth fallback.
class WooCommerceRestApi {
  WooCommerceRestApi._();
  static final WooCommerceRestApi instance = WooCommerceRestApi._();

  static String get _v3Base => '$kStoreBaseUrl/wp-json/wc/v3';

  static String? get _basicAuthHeader {
    if (kWooKey.isEmpty || kWooSecret.isEmpty) return null;
    final token = base64Encode(utf8.encode('$kWooKey:$kWooSecret'));
    return 'Basic $token';
  }

  Map<String, String> _jsonHeaders(String jwt) => {
        'Authorization': 'Bearer $jwt',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'User-Agent': kAppUserAgent,
      };

  /// Orders placed by this customer (newest first).
  Future<List<WooOrderSummary>> fetchCustomerOrders({
    required String jwt,
    required int customerId,
    int perPage = 25,
  }) async {
    final uri = Uri.parse('$_v3Base/orders').replace(queryParameters: {
      'customer': '$customerId',
      'per_page': '$perPage',
      'orderby': 'date',
      'order': 'desc',
      'status': 'any',
    });
    try {
      final res = await http
          .get(uri, headers: _jsonHeaders(jwt))
          .timeout(const Duration(seconds: 20));
      if (kDebugMode) {
        debugPrint(
          '[WooRest] GET orders customer=$customerId → ${res.statusCode}',
        );
      }
      if (res.statusCode != 200) {
        final basic = _basicAuthHeader;
        if (basic != null) {
          final fallback = await http
              .get(
                uri,
                headers: {
                  'Authorization': basic,
                  'Accept': 'application/json',
                  'User-Agent': kAppUserAgent,
                },
              )
              .timeout(const Duration(seconds: 20));
          if (kDebugMode) {
            debugPrint(
              '[WooRest] fallback Basic GET orders customer=$customerId → ${fallback.statusCode}',
            );
          }
          if (fallback.statusCode == 200) {
            final decoded = jsonDecode(fallback.body);
            if (decoded is List) {
              return decoded
                  .map((e) => WooOrderSummary.fromJson(e as Map<String, dynamic>))
                  .toList();
            }
          }
        }
        if (kDebugMode) {
          debugPrint(
            '[WooRest] orders body: ${res.body.length > 500 ? res.body.substring(0, 500) : res.body}',
          );
        }
        return const [];
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! List) return const [];
      return decoded
          .map((e) => WooOrderSummary.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e, st) {
      if (kDebugMode) debugPrint('[WooRest] fetchCustomerOrders error: $e\n$st');
      return const [];
    }
  }

  /// True if the customer has at least one completed order (MOQ “returning” wholesale rule).
  Future<bool> customerHasCompletedOrder({
    required String jwt,
    required int customerId,
  }) async {
    final uri = Uri.parse('$_v3Base/orders').replace(queryParameters: {
      'customer': '$customerId',
      'per_page': '1',
      'status': 'completed',
    });
    try {
      final res = await http
          .get(uri, headers: _jsonHeaders(jwt))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is List) return decoded.isNotEmpty;
      }
      final basic = _basicAuthHeader;
      if (basic == null) return false;
      final fallback = await http
          .get(
            uri,
            headers: {
              'Authorization': basic,
              'Accept': 'application/json',
              'User-Agent': kAppUserAgent,
            },
          )
          .timeout(const Duration(seconds: 20));
      if (fallback.statusCode != 200) return false;
      final decoded = jsonDecode(fallback.body);
      if (decoded is! List) return false;
      return decoded.isNotEmpty;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[WooRest] customerHasCompletedOrder error: $e\n$st');
      }
      return false;
    }
  }

  /// Single order (includes `line_items`).
  Future<WooOrderSummary?> fetchOrderById({
    required String jwt,
    required int orderId,
    required int customerId,
  }) async {
    final uri = Uri.parse('$_v3Base/orders/$orderId');
    try {
      final res = await http
          .get(uri, headers: _jsonHeaders(jwt))
          .timeout(const Duration(seconds: 20));
      Map<String, dynamic>? body;
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) {
          body = decoded;
        }
      } else {
        final basic = _basicAuthHeader;
        if (basic != null) {
          final fallback = await http
              .get(
                uri,
                headers: {
                  'Authorization': basic,
                  'Accept': 'application/json',
                  'User-Agent': kAppUserAgent,
                },
              )
              .timeout(const Duration(seconds: 20));
          if (fallback.statusCode == 200) {
            final decoded = jsonDecode(fallback.body);
            if (decoded is Map<String, dynamic>) {
              body = decoded;
            }
          }
        }
      }
      if (body == null) return null;
      final o = WooOrderSummary.fromJson(body);
      final cid = o.customerId;
      if (cid != null && cid != customerId) return null;
      return o;
    } catch (e, st) {
      if (kDebugMode) debugPrint('[WooRest] fetchOrderById error: $e\n$st');
      return null;
    }
  }

  /// Creates a pending wholesale order (bank deposit / phone credit card).
  Future<({WooOrderSummary? order, String? error})> createWholesaleOrder({
    required String jwt,
    required int customerId,
    required List<({int productId, int quantity})> lineItems,
    required String paymentMethod,
    required String paymentMethodTitle,
  }) async {
    if (lineItems.isEmpty) {
      return (order: null, error: 'Cart is empty.');
    }

    final uri = Uri.parse('$_v3Base/orders');
    final payload = <String, dynamic>{
      'customer_id': customerId,
      'payment_method': paymentMethod,
      'payment_method_title': paymentMethodTitle,
      'set_paid': false,
      'status': 'on-hold',
      'line_items': lineItems
          .map((e) => {
                'product_id': e.productId,
                'quantity': e.quantity,
              })
          .toList(),
    };

    Future<http.Response> post(Map<String, String> headers) => http
        .post(
          uri,
          headers: headers,
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 30));

    try {
      var res = await post(_jsonHeaders(jwt));
      if (res.statusCode != 201 && _basicAuthHeader != null) {
        res = await post({
          'Authorization': _basicAuthHeader!,
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'User-Agent': kAppUserAgent,
        });
      }

      if (kDebugMode) {
        debugPrint('[WooRest] POST orders → ${res.statusCode}');
      }

      if (res.statusCode != 201) {
        var msg = 'Order could not be created (${res.statusCode}).';
        try {
          final decoded = jsonDecode(res.body);
          if (decoded is Map && decoded['message'] != null) {
            msg = decoded['message'].toString();
          }
        } catch (_) {}
        return (order: null, error: msg);
      }

      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) {
        return (order: null, error: 'Unexpected response from store.');
      }
      return (order: WooOrderSummary.fromJson(decoded), error: null);
    } catch (e, st) {
      if (kDebugMode) debugPrint('[WooRest] createWholesaleOrder error: $e\n$st');
      return (order: null, error: 'Network error creating order.');
    }
  }
}
