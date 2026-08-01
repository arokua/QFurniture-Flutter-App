import 'package:Qtoys/features/checkout/data/checkout_bridges.dart';
import 'package:Qtoys/features/orders/domain/woo_order_summary.dart';

/// Records how the cart was touched, so a test can assert the single rule that
/// matters: the cart is emptied only against a real order id.
class FakeCheckoutCartBridge implements CheckoutCartBridge {
  bool drainResult = true;

  final List<String> holdsBegun = <String>[];

  /// Every endHold call, in order, as (attemptId, clearCart).
  final List<({String attemptId, bool clearCart})> holdsEnded =
      <({String attemptId, bool clearCart})>[];

  int remoteCartClears = 0;

  /// True if any call was allowed to empty the basket.
  bool get cartWasCleared => holdsEnded.any((h) => h.clearCart);

  bool get holdIsOpen => holdsBegun.length > holdsEnded.length;

  @override
  Future<bool> drainForCheckout() async => drainResult;

  @override
  Future<void> beginHold(String attemptId) async => holdsBegun.add(attemptId);

  @override
  Future<void> endHold(String attemptId, {required bool clearCart}) async =>
      holdsEnded.add((attemptId: attemptId, clearCart: clearCart));

  @override
  Future<void> clearRemoteCart() async => remoteCartClears++;
}

/// Scripted order lookup.
///
/// [reachedServer] is modelled explicitly because conflating "not found" with
/// "could not check" is the exact bug that would lose a real order.
class FakeCheckoutOrderLookup implements CheckoutOrderLookup {
  FakeCheckoutOrderLookup({this.canLook = true});

  bool canLook;

  /// Orders the fake server knows about, keyed by client order key.
  final Map<String, WooOrderSummary> ordersByClientKey =
      <String, WooOrderSummary>{};

  /// When false, every lookup reports that the server could not be reached.
  bool serverReachable = true;

  final List<String> lookups = <String>[];

  @override
  Future<bool> canLookup() async => canLook;

  @override
  Future<({WooOrderSummary? order, bool reachedServer})> findByClientKey(
    String clientOrderKey,
  ) async {
    lookups.add(clientOrderKey);
    if (!serverReachable) return (order: null, reachedServer: false);
    return (order: ordersByClientKey[clientOrderKey], reachedServer: true);
  }
}

class FakeCheckoutHistoryBridge implements CheckoutHistoryBridge {
  final List<String> resolved = <String>[];
  final List<String> failed = <String>[];
  final List<WooOrderSummary> written = <WooOrderSummary>[];
  int pendingWrites = 0;

  @override
  Future<String> writePending({
    required String total,
    required List<WooOrderLineItem> lineItems,
  }) async {
    pendingWrites++;
    return 'pending_$pendingWrites';
  }

  @override
  Future<void> resolvePending({
    required String localRef,
    required WooOrderSummary order,
  }) async =>
      resolved.add(localRef);

  @override
  Future<void> failPending({
    required String localRef,
    required String error,
  }) async =>
      failed.add(localRef);

  @override
  Future<void> writeOrder(WooOrderSummary order) async => written.add(order);
}

/// A confirmed WooCommerce order.
WooOrderSummary fakeOrder({int id = 4821, String number = '4821'}) =>
    WooOrderSummary(
      id: id,
      number: number,
      status: 'on-hold',
      dateCreated: DateTime.utc(2026, 8, 1, 12),
      total: '1284.00',
      currency: 'AUD',
      customerId: 7,
    );
