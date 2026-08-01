import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

import '../../../config/checkout_engine_config.dart';
import '../../orders/domain/woo_order_summary.dart';
import '../domain/checkout_attempt.dart';
import 'checkout_attempt_store.dart';
import 'checkout_bridges.dart';

/// What a reconcile pass concluded, for the caller's messaging and for tests.
enum CheckoutReconcileOutcome {
  /// No persisted attempt, or the record was already terminal.
  nothingToDo,

  /// The record never reached dispatch, so the order provably was not sent.
  /// The cart was handed straight back.
  abandoned,

  /// A matching order was found on the server. The cart has been cleared.
  confirmed,

  /// The server was reachable, the order is genuinely not there, and the
  /// attempt is past the grace window. The cart was preserved.
  failed,

  /// Could not be settled this pass (offline, no session, still inside the
  /// grace window). The record is kept and will be retried.
  deferred,
}

class CheckoutReconcileResult {
  const CheckoutReconcileResult(this.outcome, {this.order, this.message});

  final CheckoutReconcileOutcome outcome;
  final WooOrderSummary? order;

  /// Friendly, user-facing text. Null when there is nothing worth saying.
  final String? message;
}

/// Owns the persisted checkout attempt record and the cart's checkout hold.
///
/// The invariant this class exists to enforce:
///
/// > **The cart is cleared only against a real WooCommerce order id.**
///
/// Everything else follows from it. The record is written to disk in
/// [CheckoutAttemptState.dispatched] *before* the order request goes out, so
/// after any crash the app can tell whether the POST could possibly have been
/// sent. An attempt is never resubmitted automatically — an ambiguous outcome
/// is resolved by asking the server whether the order exists, because
/// resubmitting would risk charging a customer twice.
class CheckoutAttemptCoordinator {
  CheckoutAttemptCoordinator({
    required CheckoutCartBridge cart,
    required CheckoutOrderLookup lookup,
    required CheckoutHistoryBridge history,
    required Future<String> Function() userKeyProvider,
    CheckoutAttemptStore? store,
    DateTime Function()? clock,
  })  : _cart = cart,
        _lookup = lookup,
        _history = history,
        _userKey = userKeyProvider,
        _store = store ?? CheckoutAttemptStore(),
        _now = clock ?? DateTime.now;

  final CheckoutCartBridge _cart;
  final CheckoutOrderLookup _lookup;
  final CheckoutHistoryBridge _history;
  final Future<String> Function() _userKey;
  final CheckoutAttemptStore _store;
  final DateTime Function() _now;

  /// Serializes every transition so a reconcile pass cannot interleave with a
  /// live submission and write a stale record over a newer one.
  Future<void> _opChain = Future<void>.value();

  bool _reconcileInFlight = false;

  Future<CheckoutAttempt?> current() => _store.read();

  // ------------------------------------------------------------ transitions

  /// Persists a new attempt and freezes the cart.
  ///
  /// Returns null when another attempt is still outstanding — that is the
  /// duplicate-order guard. It replaces an in-memory 2-second time bucket,
  /// which could not survive a process restart and minted a fresh key on every
  /// retry, defeating its own purpose.
  Future<CheckoutAttempt?> begin({
    required List<CheckoutAttemptLine> lines,
    String? totalDisplay,
    bool drainSettled = true,
  }) async {
    return _enqueue(() async {
      if (lines.isEmpty) return null;

      final existing = await _store.read();
      if (existing != null && !existing.isTerminal) {
        // An attempt that has been unresolvable for hours must not lock the
        // customer out of ordering forever. Retire it (keeping the basket) and
        // let this checkout proceed.
        if (!existing.isOlderThan(
          CheckoutEngineConfig.attemptStaleAfter,
          _now(),
        )) {
          return null;
        }
        await _fail(existing, 'Order could not be confirmed.');
      }

      final attempt = CheckoutAttempt.starting(
        userKey: await _userKey(),
        lines: lines,
        now: _now(),
        totalDisplay: totalDisplay,
        drainSettled: drainSettled,
      );
      await _store.write(attempt);
      await _cart.beginHold(attempt.attemptId);
      return attempt;
    });
  }

  /// Records that the order request is about to leave.
  ///
  /// Must be awaited *before* the POST: this write is what makes a later crash
  /// attributable rather than a guess.
  Future<CheckoutAttempt?> markDispatched(
    String attemptId, {
    String? localRef,
  }) {
    return _enqueue(() async {
      final attempt = await _requireAttempt(attemptId);
      if (attempt == null) return null;
      final updated = attempt.copyWith(
        state: CheckoutAttemptState.dispatched,
        dispatchedAt: _now(),
        localRef: localRef,
      );
      await _store.write(updated);
      return updated;
    });
  }

  /// The only path that clears the cart.
  Future<void> markConfirmed(
    String attemptId, {
    required WooOrderSummary order,
  }) {
    return _enqueue(() async {
      final attempt = await _requireAttempt(attemptId);
      if (attempt == null) return;
      await _confirm(attempt, order);
    });
  }

  /// The server said no. The basket is left exactly as it was.
  Future<void> markFailed(String attemptId, {required String error}) {
    return _enqueue(() async {
      final attempt = await _requireAttempt(attemptId);
      if (attempt == null) return;
      await _fail(attempt, error);
    });
  }

  /// Dispatched, outcome indeterminate. Keeps the basket and leaves the record
  /// for reconciliation.
  Future<void> markUnknown(String attemptId, {required String error}) {
    return _enqueue(() async {
      final attempt = await _requireAttempt(attemptId);
      if (attempt == null) return;
      final updated = attempt.copyWith(
        state: CheckoutAttemptState.unknown,
        error: error,
        updatedAt: _now(),
      );
      await _store.write(updated);
      // Release the freeze but keep the cart: the user must be able to shop
      // again, and if the order did land, reconciliation clears it shortly.
      await _cart.endHold(attempt.attemptId, clearCart: false);
    });
  }

  /// Drops a record that never dispatched and unfreezes the cart.
  Future<void> abandon(String attemptId) {
    return _enqueue(() async {
      final attempt = await _requireAttempt(attemptId);
      if (attempt == null) return;
      await _cart.endHold(attempt.attemptId, clearCart: false);
      await _store.clear();
    });
  }

  // ----------------------------------------------------------- reconciliation

  /// Settles any outstanding attempt. Safe to call on every launch and resume.
  Future<CheckoutReconcileResult> reconcile() async {
    if (_reconcileInFlight) {
      return const CheckoutReconcileResult(CheckoutReconcileOutcome.deferred);
    }
    _reconcileInFlight = true;
    try {
      return await _enqueue(_reconcileLocked);
    } finally {
      _reconcileInFlight = false;
    }
  }

  Future<CheckoutReconcileResult> _reconcileLocked() async {
    final attempt = await _store.read();
    if (attempt == null) {
      return const CheckoutReconcileResult(CheckoutReconcileOutcome.nothingToDo);
    }

    if (attempt.isTerminal) {
      // A settled record left over from a previous run; nothing depends on it.
      await _store.clear();
      return const CheckoutReconcileResult(CheckoutReconcileOutcome.nothingToDo);
    }

    if (attempt.isAbandonable) {
      // Still `preparing`, so the request never went out. No server round trip
      // is needed to know this.
      await _cart.endHold(attempt.attemptId, clearCart: false);
      await _store.clear();
      return const CheckoutReconcileResult(
        CheckoutReconcileOutcome.abandoned,
        message: 'Your order was not sent. Your cart is still here.',
      );
    }

    if (!await _lookup.canLookup()) {
      return const CheckoutReconcileResult(CheckoutReconcileOutcome.deferred);
    }

    final result = await _lookup.findByClientKey(attempt.clientOrderKey);

    final order = result.order;
    if (order != null && order.id > 0) {
      await _confirm(attempt, order);
      return CheckoutReconcileResult(
        CheckoutReconcileOutcome.confirmed,
        order: order,
        message: 'Order #${order.number} went through.',
      );
    }

    if (!result.reachedServer) {
      // Could not check. Emphatically not the same as "no order" — treating it
      // as failure here is exactly how a real order would be lost.
      if (attempt.isOlderThan(
            CheckoutEngineConfig.attemptStaleAfter,
            _now(),
          ) &&
          attempt.lookupAttempts + 1 >= CheckoutEngineConfig.maxLookupAttempts) {
        // The store has been unreachable for hours. Stop probing and stop
        // blocking new orders, but say plainly that the outcome is unknown
        // rather than claiming the order failed — it may well exist.
        await _fail(attempt, 'Order could not be confirmed.');
        return const CheckoutReconcileResult(
          CheckoutReconcileOutcome.failed,
          message: "We still couldn't confirm your last order. "
              'Please check your order history before ordering again.',
        );
      }
      await _bumpLookup(attempt);
      return const CheckoutReconcileResult(CheckoutReconcileOutcome.deferred);
    }

    final exhausted =
        attempt.lookupAttempts + 1 >= CheckoutEngineConfig.maxLookupAttempts;
    if (!attempt.isOlderThan(CheckoutEngineConfig.reconcileGrace, _now()) &&
        !exhausted) {
      // Inside the grace window: WooCommerce may still be writing the order.
      await _bumpLookup(attempt);
      return const CheckoutReconcileResult(CheckoutReconcileOutcome.deferred);
    }

    await _fail(attempt, 'Order was not received by the store.');
    return const CheckoutReconcileResult(
      CheckoutReconcileOutcome.failed,
      message: "Your order didn't go through. "
          'Your cart is still here so you can try again.',
    );
  }

  // --------------------------------------------------------------- internals

  Future<void> _confirm(CheckoutAttempt attempt, WooOrderSummary order) async {
    final updated = attempt.copyWith(
      state: CheckoutAttemptState.confirmed,
      orderId: order.id,
      orderNumber: order.number,
      resolvedAt: _now(),
      clearError: true,
    );
    // Persist the terminal state before touching the cart: if the process dies
    // between these two steps, the next reconcile finds a confirmed record and
    // finishes the job instead of re-asking the server.
    await _store.write(updated);

    final localRef = attempt.localRef;
    if (localRef != null && localRef.isNotEmpty) {
      await _history.resolvePending(localRef: localRef, order: order);
    } else {
      await _history.writeOrder(order);
    }

    await _cart.clearRemoteCart();
    await _cart.endHold(attempt.attemptId, clearCart: true);
    await _store.clear();
  }

  Future<void> _fail(CheckoutAttempt attempt, String error) async {
    final updated = attempt.copyWith(
      state: CheckoutAttemptState.failed,
      error: error,
      resolvedAt: _now(),
    );
    await _store.write(updated);

    final localRef = attempt.localRef;
    if (localRef != null && localRef.isNotEmpty) {
      await _history.failPending(localRef: localRef, error: error);
    }

    // clearCart: false is the entire point — the basket survives the failure.
    await _cart.endHold(attempt.attemptId, clearCart: false);
    await _store.clear();
  }

  Future<void> _bumpLookup(CheckoutAttempt attempt) async {
    await _store.write(attempt.copyWith(
      state: CheckoutAttemptState.unknown,
      lookupAttempts: attempt.lookupAttempts + 1,
      updatedAt: _now(),
    ));
  }

  /// Guards every transition against acting on a record that has been replaced
  /// or already settled by a concurrent reconcile.
  Future<CheckoutAttempt?> _requireAttempt(String attemptId) async {
    final attempt = await _store.read();
    if (attempt == null || attempt.attemptId != attemptId) {
      if (kDebugMode) {
        debugPrint('[Checkout] transition for stale attempt $attemptId');
      }
      return null;
    }
    return attempt.isTerminal ? null : attempt;
  }

  /// Runs [action] on the serial chain so transitions cannot interleave.
  Future<T> _enqueue<T>(Future<T> Function() action) {
    final next = _opChain.then((_) => action());
    _opChain = next.then<void>((_) {}, onError: (_) {});
    return next;
  }
}
