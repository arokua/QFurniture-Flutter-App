import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:http/http.dart' as http;

import '../config/store_config.dart';
import '../features/orders/domain/woo_order_summary.dart';

/// WooCommerce REST API (`/wp-json/wc/v3/...`) using the same JWT as [AuthService].
///
/// Requires the server to allow Bearer JWT on WC REST routes (common with JWT plugins).
class WooCommerceRestApi {
  WooCommerceRestApi._();
  static final WooCommerceRestApi instance = WooCommerceRestApi._();

  static String get _base => '$kStoreBaseUrl/wp-json/wc/v3';

  /// Orders placed by this customer (newest first).
  Future<List<WooOrderSummary>> fetchCustomerOrders({
    required String jwt,
    required int customerId,
    int perPage = 25,
  }) async {
    final uri = Uri.parse('$_base/orders').replace(queryParameters: {
      'customer': '$customerId',
      'per_page': '$perPage',
      'orderby': 'date',
      'order': 'desc',
      'status': 'any',
    });
    try {
      final res = await http
          .get(
            uri,
            headers: {
              'Authorization': 'Bearer $jwt',
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (kDebugMode) {
        debugPrint(
          '[WooRest] GET orders customer=$customerId → ${res.statusCode}',
        );
      }
      if (res.statusCode != 200) {
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
}
