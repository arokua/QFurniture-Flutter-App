import '../../../config/checkout_engine_config.dart';
import '../../../config/store_cart_api_service.dart';
import '../../../navigation/checkout_feedback.dart';
import '../../../services/auth_service.dart';
import '../../../services/cart_sync_service.dart';
import '../../../services/order_history_sync_service.dart';
import '../../../services/woo_commerce_rest_api.dart';
import '../../cart/data/cart_providers.dart';
import '../../orders/domain/woo_order_summary.dart';
import 'checkout_attempt_coordinator.dart';
import 'checkout_bridges.dart';

/// Cart side of checkout, backed by the real single-writer engine.
class StoreCheckoutCartBridge implements CheckoutCartBridge {
  const StoreCheckoutCartBridge();

  @override
  Future<bool> drainForCheckout() =>
      cartCoordinator.drainForCheckout(timeout: CheckoutEngineConfig.drainTimeout);

  @override
  Future<void> beginHold(String attemptId) =>
      cartCoordinator.beginCheckoutHold(attemptId);

  @override
  Future<void> endHold(String attemptId, {required bool clearCart}) =>
      cartCoordinator.endCheckoutHold(attemptId, clearCart: clearCart);

  @override
  Future<void> clearRemoteCart() async {
    await StoreCartApiService.instance.clearCart();
    await cartCoordinator.markEmptySynced();
  }
}

/// Order lookup by client key, backed by wc/v3.
class WooCheckoutOrderLookup implements CheckoutOrderLookup {
  const WooCheckoutOrderLookup();

  @override
  Future<bool> canLookup() async {
    if (!AuthService.instance.isSignedIn) return false;
    final token = AuthService.instance.currentSession?.token;
    if (token == null || token.isEmpty) return false;
    final customerId =
        await AuthService.instance.ensureCustomerIdForCurrentSession();
    return customerId != null && customerId > 0;
  }

  @override
  Future<({WooOrderSummary? order, bool reachedServer})> findByClientKey(
    String clientOrderKey,
  ) async {
    final token = AuthService.instance.currentSession?.token;
    if (token == null || token.isEmpty) {
      return (order: null, reachedServer: false);
    }
    final customerId =
        await AuthService.instance.ensureCustomerIdForCurrentSession();
    if (customerId == null || customerId <= 0) {
      return (order: null, reachedServer: false);
    }
    return WooCommerceRestApi.instance.findOrderByClientOrderKey(
      jwt: token,
      customerId: customerId,
      clientOrderKey: clientOrderKey,
    );
  }
}

/// Local order-history write-through.
class OrderHistoryCheckoutBridge implements CheckoutHistoryBridge {
  const OrderHistoryCheckoutBridge();

  @override
  Future<String> writePending({
    required String total,
    required List<WooOrderLineItem> lineItems,
  }) =>
      OrderHistorySyncService.instance.writeThroughPendingOrder(
        number: '…',
        total: total,
        lineItems: lineItems,
      );

  @override
  Future<void> resolvePending({
    required String localRef,
    required WooOrderSummary order,
  }) async {
    await OrderHistorySyncService.instance
        .resolvePendingOrder(localRef: localRef, order: order);
    OrderHistorySyncService.instance.syncNow(force: true).ignore();
  }

  @override
  Future<void> failPending({
    required String localRef,
    required String error,
  }) =>
      OrderHistorySyncService.instance
          .failPendingOrder(localRef: localRef, error: error);

  @override
  Future<void> writeOrder(WooOrderSummary order) =>
      OrderHistorySyncService.instance.writeThroughOrder(order);
}

CheckoutAttemptCoordinator? _coordinator;

/// The app-wide checkout attempt engine.
CheckoutAttemptCoordinator get checkoutCoordinator =>
    _coordinator ??= CheckoutAttemptCoordinator(
      cart: const StoreCheckoutCartBridge(),
      lookup: const WooCheckoutOrderLookup(),
      history: const OrderHistoryCheckoutBridge(),
      userKeyProvider: () => CartSyncService.instance.currentUserKey(),
    );

/// Test seam: drops the singleton so a fresh engine can be installed.
void resetCheckoutCoordinatorForTest([CheckoutAttemptCoordinator? replacement]) {
  _coordinator = replacement;
}

/// Settles an outstanding checkout attempt and tells the user what happened.
///
/// Safe to call on every launch and resume: with no attempt on disk it is a
/// single file read that returns [CheckoutReconcileOutcome.nothingToDo].
Future<CheckoutReconcileResult> reconcileCheckoutAttempt() async {
  final result = await checkoutCoordinator.reconcile();
  final message = result.message;
  if (message != null && message.isNotEmpty) {
    showCheckoutFeedbackSnackBar(message);
  }
  if (result.outcome == CheckoutReconcileOutcome.confirmed) {
    OrderHistorySyncService.instance.syncNow(force: true).ignore();
  }
  return result;
}
