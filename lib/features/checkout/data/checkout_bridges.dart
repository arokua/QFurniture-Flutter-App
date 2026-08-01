import '../../orders/domain/woo_order_summary.dart';

/// The cart operations checkout needs, as a seam.
///
/// Kept abstract so [CheckoutAttemptCoordinator] can be tested without the
/// real cart engine, file system or network — the same reason
/// `CartRemoteGateway` exists.
abstract class CheckoutCartBridge {
  /// The checkout barrier: settles queued cart mutations so the order is
  /// placed against a basket the server has actually confirmed. False means
  /// work is still outstanding and checkout should not proceed.
  Future<bool> drainForCheckout();

  /// Freezes cart mutations for the duration of an attempt.
  Future<void> beginHold(String attemptId);

  /// Releases the freeze. [clearCart] must only ever be true once a real
  /// WooCommerce order id exists.
  Future<void> endHold(String attemptId, {required bool clearCart});

  /// Empties the WooCommerce-side cart after a confirmed order, so a later
  /// reconcile cannot rehydrate a basket that has already been ordered.
  Future<void> clearRemoteCart();
}

/// Looks up an order the app previously submitted.
abstract class CheckoutOrderLookup {
  /// False when there is no session or customer id to search with, so
  /// reconciliation defers instead of concluding anything.
  Future<bool> canLookup();

  /// [reachedServer] distinguishes "not there" from "could not check".
  Future<({WooOrderSummary? order, bool reachedServer})> findByClientKey(
    String clientOrderKey,
  );
}

/// Local order-history write-through.
abstract class CheckoutHistoryBridge {
  Future<String> writePending({
    required String total,
    required List<WooOrderLineItem> lineItems,
  });

  Future<void> resolvePending({
    required String localRef,
    required WooOrderSummary order,
  });

  Future<void> failPending({
    required String localRef,
    required String error,
  });

  Future<void> writeOrder(WooOrderSummary order);
}
