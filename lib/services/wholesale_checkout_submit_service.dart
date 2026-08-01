import 'dart:async';

import '../features/cart/data/store_cart_snapshot.dart';
import '../features/cart/domain/role_cart_pricing.dart';
import '../features/checkout/data/checkout_providers.dart';
import '../features/checkout/domain/checkout_attempt.dart';
import '../features/orders/domain/woo_order_summary.dart';
import '../navigation/checkout_feedback.dart';
import 'auth_service.dart';
import 'woo_commerce_rest_api.dart';

/// Posts native checkout orders after the UI has already returned home.
///
/// Every step is ordered around one rule: **the cart is cleared only against a
/// real WooCommerce order id.** The attempt record is persisted in
/// [CheckoutAttemptState.dispatched] before the POST leaves, so if the process
/// dies at any point the next launch can tell whether an order might exist and
/// resolve it by lookup rather than by resubmitting.
class WholesaleCheckoutSubmitService {
  WholesaleCheckoutSubmitService._();

  static final WholesaleCheckoutSubmitService instance =
      WholesaleCheckoutSubmitService._();

  bool _submitInFlight = false;

  /// True while a background POST is running (UI can avoid re-submit).
  bool get isSubmitting => _submitInFlight;

  /// Submits [attempt], which must already be persisted in
  /// [CheckoutAttemptState.preparing] by [CheckoutAttemptCoordinator.begin].
  ///
  /// Taking the attempt as a parameter — rather than minting a key here — is
  /// what makes the client order key stable across retries and restarts. The
  /// previous implementation derived it from a 2-second time bucket, so a
  /// retry produced a different key and the dedupe silently stopped working.
  Future<void> submitInBackground({
    required String jwt,
    required CheckoutAttempt attempt,
    int? customerId,
    required StoreCartApiSnapshot snapshot,
    required List<({int productId, int quantity})> lines,
    required String paymentMethod,
    required String paymentMethodTitle,
    required String accountType,
    required List<Map<String, String>> orderMeta,
  }) async {
    if (_submitInFlight) return;
    _submitInFlight = true;

    final coordinator = checkoutCoordinator;
    try {
      var resolvedCustomerId = customerId;
      resolvedCustomerId ??=
          await AuthService.instance.ensureCustomerIdForCurrentSession();
      if (resolvedCustomerId == null) {
        // Nothing was sent, so the basket is handed straight back.
        await coordinator.abandon(attempt.attemptId);
        showCheckoutFeedbackSnackBar(
          'Sign in again to place your order. Your cart is still here.',
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

      final localRef = await const OrderHistoryCheckoutBridge().writePending(
        total: totalDisplay.replaceAll(RegExp(r'[^\d.]'), ''),
        lineItems: pendingLines,
      );

      // Persist `dispatched` BEFORE the request goes out. This single ordering
      // is what makes a crash attributable instead of a guess.
      final dispatched = await coordinator.markDispatched(
        attempt.attemptId,
        localRef: localRef,
      );
      if (dispatched == null) {
        // The record was settled or replaced underneath us (e.g. a reconcile
        // already confirmed it). Do not send a second order.
        return;
      }

      final billingEmail = await AuthService.instance.resolvedAccountEmail();
      final roleLinePrices = RoleCartPricing.fromSnapshotLines(snapshot.lines);

      final metaWithClientKey = <Map<String, String>>[
        ...orderMeta,
        {
          'key': WooCommerceRestApi.clientOrderKeyMeta,
          'value': attempt.clientOrderKey,
        },
      ];

      final result = await WooCommerceRestApi.instance.createWholesaleOrder(
        jwt: jwt,
        customerId: resolvedCustomerId,
        lineItems: lines,
        paymentMethod: paymentMethod,
        paymentMethodTitle: paymentMethodTitle,
        billingEmail: billingEmail,
        accountType: accountType,
        orderMeta: metaWithClientKey,
        roleLinePrices: roleLinePrices,
      );

      final order = result.order;
      if (order != null && order.id > 0) {
        await coordinator.markConfirmed(attempt.attemptId, order: order);
        showCheckoutFeedbackSnackBar('Order #${order.number} placed.');
        return;
      }

      if (result.ambiguous) {
        // The order may exist. Keep the basket, keep the record, and let
        // reconciliation settle it. Never resubmit.
        await coordinator.markUnknown(
          attempt.attemptId,
          error: result.error ?? 'Could not confirm the order.',
        );
        showCheckoutFeedbackSnackBar(
          "We couldn't confirm your order yet. "
          "We'll check again shortly — your cart is safe.",
        );
        return;
      }

      await coordinator.markFailed(
        attempt.attemptId,
        error: result.error ?? 'Could not create order.',
      );
      showCheckoutFeedbackSnackBar(
        "Your order didn't go through. "
        'Your cart is still here so you can try again.',
      );
    } catch (e, st) {
      // An exception here is ambiguous by definition: we do not know how far
      // the request got, so the cart must survive.
      await coordinator.markUnknown(
        attempt.attemptId,
        error: 'Order submission was interrupted.',
      );
      showCheckoutFeedbackSnackBar(
        "We couldn't confirm your order yet. "
        "We'll check again shortly — your cart is safe.",
      );
      assert(() {
        // ignore: avoid_print
        print('[WholesaleCheckoutSubmit] $e\n$st');
        return true;
      }());
    } finally {
      _submitInFlight = false;
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
