import 'dart:async';

import '../features/cart/data/store_cart_snapshot.dart';
import '../features/cart/domain/role_cart_pricing.dart';
import '../features/orders/domain/woo_order_summary.dart';
import '../navigation/checkout_feedback.dart';
import 'auth_service.dart';
import 'cart_sync_service.dart';
import 'order_history_sync_service.dart';
import 'woo_commerce_rest_api.dart';
import '../config/store_cart_api_service.dart';

/// Posts wholesale orders after the UI has already returned home.
class WholesaleCheckoutSubmitService {
  WholesaleCheckoutSubmitService._();

  static final WholesaleCheckoutSubmitService instance =
      WholesaleCheckoutSubmitService._();

  Future<void> submitInBackground({
    required String jwt,
    int? customerId,
    required StoreCartApiSnapshot snapshot,
    required List<({int productId, int quantity})> lines,
    required String paymentMethod,
    required String paymentMethodTitle,
    required String accountType,
    required List<Map<String, String>> orderMeta,
  }) async {
    String pendingRef = '';
    try {
      var resolvedCustomerId = customerId;
      resolvedCustomerId ??=
          await AuthService.instance.ensureCustomerIdForCurrentSession();
      if (resolvedCustomerId == null) {
        showCheckoutFeedbackSnackBar(
          'Sign in again to place your order.',
        );
        return;
      }

      final totalDisplay = snapshot.totalsView.formattedTotal ??
          _fallbackTotal(snapshot).toStringAsFixed(2);
      final pendingLines = snapshot.lines
          .map(
            (l) => WooOrderLineItem(
              productId: l.productId,
              quantity: l.quantity,
              name: l.name,
            ),
          )
          .toList();
      pendingRef = await OrderHistorySyncService.instance
          .writeThroughPendingOrder(
        number: '…',
        total: totalDisplay.replaceAll(RegExp(r'[^\d.]'), ''),
        lineItems: pendingLines,
      );

      final billingEmail = await AuthService.instance.resolvedAccountEmail();
      final roleLinePrices = RoleCartPricing.fromSnapshotLines(snapshot.lines);

      final result = await WooCommerceRestApi.instance.createWholesaleOrder(
        jwt: jwt,
        customerId: resolvedCustomerId,
        lineItems: lines,
        paymentMethod: paymentMethod,
        paymentMethodTitle: paymentMethodTitle,
        billingEmail: billingEmail,
        accountType: accountType,
        orderMeta: orderMeta,
        roleLinePrices: roleLinePrices,
      );

      if (result.order == null) {
        if (pendingRef.isNotEmpty) {
          await OrderHistorySyncService.instance.failPendingOrder(
            localRef: pendingRef,
            error: result.error ?? 'Could not create order.',
          );
        }
        showCheckoutFeedbackSnackBar(
          result.error ?? 'Could not create order. Check order history.',
        );
        return;
      }

      if (pendingRef.isNotEmpty) {
        await OrderHistorySyncService.instance.resolvePendingOrder(
          localRef: pendingRef,
          order: result.order!,
        );
      } else {
        await OrderHistorySyncService.instance.writeThroughOrder(result.order!);
      }

      unawaited(StoreCartApiService.instance.clearCart());
      unawaited(CartSyncService.instance.clearCurrentCart());
      OrderHistorySyncService.instance.syncNow(force: true).ignore();
    } catch (e, st) {
      if (pendingRef.isNotEmpty) {
        await OrderHistorySyncService.instance.failPendingOrder(
          localRef: pendingRef,
          error: 'Order could not be submitted.',
        );
      }
      showCheckoutFeedbackSnackBar(
        'Order could not be submitted. Check order history.',
      );
      assert(() {
        // ignore: avoid_print
        print('[WholesaleCheckoutSubmit] $e\n$st');
        return true;
      }());
    }
  }

  double _fallbackTotal(StoreCartApiSnapshot snap) {
    var total = 0.0;
    for (final l in snap.lines) {
      final minor = l.lineTotalMinor ??
          (l.priceMinor != null ? l.priceMinor! * l.quantity : 0);
      var d = 1.0;
      for (var i = 0; i < l.minorUnit; i++) {
        d *= 10;
      }
      total += minor / d;
    }
    return total;
  }
}
