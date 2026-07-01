import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:shared_preferences/shared_preferences.dart';

import '../features/orders/domain/woo_order_summary.dart';
import '../features/orders/domain/order_history_load_result.dart';
import 'auth_service.dart';
import 'order_history_cache_service.dart';
import 'woo_commerce_rest_api.dart';

/// Fetches order history, merges into the on-disk JSON cache, and debounces sync.
class OrderHistorySyncService {
  OrderHistorySyncService._();
  static final OrderHistorySyncService instance = OrderHistorySyncService._();

  static const _lastSyncKey = 'qf_order_history_last_sync_ms';
  static const syncInterval = Duration(minutes: 15);

  Timer? _periodic;
  bool _syncInFlight = false;

  Future<void> init() async {
    await OrderHistoryCacheService.instance.init();
    _periodic?.cancel();
    _periodic = Timer.periodic(syncInterval, (_) {
      syncNow().ignore();
    });
  }

  void dispose() {
    _periodic?.cancel();
    _periodic = null;
  }

  Future<String?> currentUserKey() async {
    final auth = AuthService.instance;
    if (!auth.isSignedIn) return null;
    await auth.ensureValidSession();
    final session = auth.currentSession;
    if (session == null) return null;

    final wpUserId = auth.wpUserIdFromCurrentToken;
    if (wpUserId != null && wpUserId > 0) return 'wp_$wpUserId';

    final customerId =
        session.customerId ?? await auth.ensureCustomerIdForCurrentSession();
    if (customerId != null && customerId > 0) return 'cust_$customerId';

    final email = await auth.resolvedAccountEmail();
    if (email.trim().isNotEmpty) {
      return 'email_${email.trim().toLowerCase().hashCode}';
    }
    return null;
  }

  /// Returns cached + network merged result when a fetch runs; null when skipped.
  Future<OrderHistoryLoadResult?> syncNow({bool force = false}) async {
    if (!AuthService.instance.isSignedIn) return null;
    if (_syncInFlight) return null;

    final prefs = await SharedPreferences.getInstance();
    final lastMs = prefs.getInt(_lastSyncKey) ?? 0;
    final elapsedMs = DateTime.now().millisecondsSinceEpoch - lastMs;
    if (!force && elapsedMs < syncInterval.inMilliseconds) {
      return null;
    }

    final userKey = await currentUserKey();
    if (userKey == null) return null;

    _syncInFlight = true;
    try {
      final auth = AuthService.instance;
      await auth.ensureValidSession();
      final session = auth.currentSession;
      final token = session?.token;
      if (token == null || token.isEmpty) return null;

      final customerId = session?.customerId ??
          await auth.ensureCustomerIdForCurrentSession(force: true);
      final email = await auth.resolvedAccountEmail();
      final wpUserId = auth.wpUserIdFromCurrentToken;

      final remote = await WooCommerceRestApi.instance.fetchOrdersForUser(
        jwt: token,
        customerId: customerId,
        wpUserId: wpUserId,
        customerEmail: email,
      );

      final cached = await OrderHistoryCacheService.instance.readOrders(userKey);
      final merged = _mergeOrders(cached, remote);
      await OrderHistoryCacheService.instance.saveOrders(userKey, merged);
      await prefs.setInt(_lastSyncKey, DateTime.now().millisecondsSinceEpoch);

      if (kDebugMode) {
        debugPrint(
          '[OrderHistorySync] saved ${merged.length} orders '
          '(remote=${remote.length} cached=${cached.length})',
        );
      }

      if (merged.isEmpty &&
          customerId == null &&
          wpUserId == null) {
        return const OrderHistoryLoadResult(orders: [], webViewFallback: true);
      }

      return OrderHistoryLoadResult(orders: merged);
    } catch (e, st) {
      if (kDebugMode) debugPrint('[OrderHistorySync] error: $e\n$st');
      return null;
    } finally {
      _syncInFlight = false;
    }
  }

  Future<void> writeThroughOrder(WooOrderSummary order) async {
    final userKey = await currentUserKey();
    if (userKey == null || order.id <= 0) return;
    await OrderHistoryCacheService.instance.upsertOrder(userKey, order);
    syncNow(force: true).ignore();
  }

  Future<void> writeThroughCheckout({
    required int orderId,
    required String orderNumber,
    String total = '0',
    String status = 'processing',
  }) async {
    await writeThroughOrder(
      WooOrderSummary(
        id: orderId,
        number: orderNumber,
        status: status,
        dateCreated: DateTime.now().toUtc(),
        total: total,
        currency: 'AUD',
      ),
    );
  }

  Future<void> clearOnSignOut() async {
    await OrderHistoryCacheService.instance.clearAll();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastSyncKey);
  }

  List<WooOrderSummary> _mergeOrders(
    List<WooOrderSummary> cached,
    List<WooOrderSummary> remote,
  ) {
    final seen = <int>{};
    final merged = <WooOrderSummary>[];
    for (final o in [...remote, ...cached]) {
      if (o.id <= 0 || !seen.add(o.id)) continue;
      merged.add(o);
    }
    merged.sort((a, b) => b.dateCreated.compareTo(a.dateCreated));
    return merged;
  }
}

/// Parses WooCommerce thank-you URLs, e.g. `/checkout/order-received/12345/`.
int? parseOrderIdFromThankYouUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final match =
      RegExp(r'/checkout/order-received/(\d+)').firstMatch(uri.path);
  if (match != null) return int.tryParse(match.group(1)!);
  final orderId = uri.queryParameters['order_id'];
  if (orderId != null) return int.tryParse(orderId);
  return null;
}

String? parseOrderNumberFromThankYouUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final key = uri.queryParameters['key'];
  if (key != null && key.isNotEmpty) return key;
  final id = parseOrderIdFromThankYouUrl(url);
  return id != null ? '$id' : null;
}
