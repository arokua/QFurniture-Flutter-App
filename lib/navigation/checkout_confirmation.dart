import 'package:flutter/material.dart';

import '../app_router.dart';
import '../features/orders/domain/woo_order_summary.dart';
import '../services/order_history_sync_service.dart';
import 'post_checkout_navigation.dart';

/// After checkout: write order to local JSON, then redirect home immediately.
class CheckoutConfirmation {
  CheckoutConfirmation._();

  static Future<void> complete({
    required String orderNumber,
    int? orderId,
    WooOrderSummary? order,
    String? total,
    String? pendingLocalRef,
  }) async {
    if (pendingLocalRef != null && pendingLocalRef.isNotEmpty && order != null) {
      await OrderHistorySyncService.instance.resolvePendingOrder(
        localRef: pendingLocalRef,
        order: order,
      );
    } else if (order != null) {
      await OrderHistorySyncService.instance.writeThroughOrder(order);
    } else if (orderId != null && orderId > 0) {
      await OrderHistorySyncService.instance.writeThroughCheckout(
        orderId: orderId,
        orderNumber: orderNumber,
        total: total ?? '0',
      );
    }

    PostCheckoutNavigation.go();
  }

  /// Legacy entry points delegate to [complete] (no blocking dialog).
  static Future<void> showAndContinue({
    required BuildContext context,
    required String orderNumber,
    int? orderId,
    WooOrderSummary? order,
    String? total,
    String? pendingLocalRef,
  }) =>
      complete(
        orderNumber: orderNumber,
        orderId: orderId,
        order: order,
        total: total,
        pendingLocalRef: pendingLocalRef,
      );

  static Future<void> showFromRoot({
    required String orderNumber,
    int? orderId,
    WooOrderSummary? order,
    String? total,
    String? pendingLocalRef,
  }) =>
      complete(
        orderNumber: orderNumber,
        orderId: orderId,
        order: order,
        total: total,
        pendingLocalRef: pendingLocalRef,
      );
}
