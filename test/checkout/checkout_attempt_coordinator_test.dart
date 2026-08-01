import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:Qtoys/config/checkout_engine_config.dart';
import 'package:Qtoys/features/checkout/data/checkout_attempt_coordinator.dart';
import 'package:Qtoys/features/checkout/data/checkout_attempt_store.dart';
import 'package:Qtoys/features/checkout/domain/checkout_attempt.dart';
import 'package:Qtoys/services/atomic_json_file.dart';

import '../support/fake_checkout_bridges.dart';

void main() {
  late Directory root;
  late CheckoutAttemptStore store;
  late FakeCheckoutCartBridge cart;
  late FakeCheckoutOrderLookup lookup;
  late FakeCheckoutHistoryBridge history;
  late DateTime now;

  CheckoutAttemptCoordinator build() => CheckoutAttemptCoordinator(
        cart: cart,
        lookup: lookup,
        history: history,
        userKeyProvider: () async => 'wp_7',
        store: store,
        clock: () => now,
      );

  setUp(() {
    AtomicJsonFile.resetChainsForTest();
    root = Directory.systemTemp.createTempSync('checkout_attempt');
    store = CheckoutAttemptStore(
      directoryProvider: () async => Directory('${root.path}/checkout_state'),
    );
    cart = FakeCheckoutCartBridge();
    lookup = FakeCheckoutOrderLookup();
    history = FakeCheckoutHistoryBridge();
    now = DateTime.utc(2026, 8, 1, 12);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  const lines = [
    CheckoutAttemptLine(productId: 11, quantity: 3, name: 'Blocks'),
    CheckoutAttemptLine(productId: 12, quantity: 1, name: 'Puzzle'),
  ];

  group('begin', () {
    test('persists the attempt and freezes the cart without emptying it',
        () async {
      final coordinator = build();
      final attempt = await coordinator.begin(lines: lines);

      expect(attempt, isNotNull);
      expect(attempt!.state, CheckoutAttemptState.preparing);
      expect(cart.holdsBegun, [attempt.attemptId]);
      expect(cart.cartWasCleared, isFalse,
          reason: 'the basket must survive until an order id exists');

      final onDisk = await store.read();
      expect(onDisk!.attemptId, attempt.attemptId);
      expect(onDisk.lines, hasLength(2));
    });

    test('refuses a second attempt while one is outstanding', () async {
      final coordinator = build();
      final first = await coordinator.begin(lines: lines);
      final second = await coordinator.begin(lines: lines);

      expect(first, isNotNull);
      expect(second, isNull, reason: 'persisted duplicate-order guard');
      expect(cart.holdsBegun, hasLength(1));
    });

    test('allows a new attempt once the previous one settled', () async {
      final coordinator = build();
      final first = await coordinator.begin(lines: lines);
      await coordinator.markDispatched(first!.attemptId);
      await coordinator.markFailed(first.attemptId, error: 'declined');

      final second = await coordinator.begin(lines: lines);
      expect(second, isNotNull);
      expect(second!.attemptId, isNot(first.attemptId));
    });

    test('the client order key is stable across dispatch and restart',
        () async {
      final coordinator = build();
      final attempt = await coordinator.begin(lines: lines);
      await coordinator.markDispatched(attempt!.attemptId);

      // A fresh coordinator models a process restart reading the same file.
      final reloaded = await build().current();
      expect(reloaded!.clientOrderKey, attempt.clientOrderKey);
      expect(reloaded.attemptId, attempt.attemptId);
    });

    test('an empty basket produces no attempt', () async {
      expect(await build().begin(lines: const []), isNull);
    });
  });

  group('outcomes', () {
    test('confirmed is the only path that clears the cart', () async {
      final coordinator = build();
      final attempt = await coordinator.begin(lines: lines);
      await coordinator.markDispatched(attempt!.attemptId, localRef: 'p1');

      await coordinator.markConfirmed(attempt.attemptId, order: fakeOrder());

      expect(cart.holdsEnded.single.clearCart, isTrue);
      expect(cart.remoteCartClears, 1);
      expect(history.resolved, ['p1']);
      expect(await store.read(), isNull, reason: 'settled record is cleaned up');
    });

    test('a definitive rejection keeps the cart', () async {
      final coordinator = build();
      final attempt = await coordinator.begin(lines: lines);
      await coordinator.markDispatched(attempt!.attemptId, localRef: 'p1');

      await coordinator.markFailed(attempt.attemptId, error: 'out of stock');

      expect(cart.cartWasCleared, isFalse);
      expect(cart.holdsEnded.single.clearCart, isFalse);
      expect(cart.remoteCartClears, 0);
      expect(history.failed, ['p1']);
    });

    test('an ambiguous outcome keeps the cart and the record', () async {
      final coordinator = build();
      final attempt = await coordinator.begin(lines: lines);
      await coordinator.markDispatched(attempt!.attemptId);

      await coordinator.markUnknown(attempt.attemptId, error: 'timeout');

      expect(cart.cartWasCleared, isFalse);
      final onDisk = await store.read();
      expect(onDisk!.state, CheckoutAttemptState.unknown,
          reason: 'the record must survive for reconciliation');
    });

    test('a transition against a stale attempt id is ignored', () async {
      final coordinator = build();
      final attempt = await coordinator.begin(lines: lines);
      await coordinator.markDispatched(attempt!.attemptId);

      await coordinator.markConfirmed('some-other-attempt', order: fakeOrder());

      expect(cart.cartWasCleared, isFalse);
      expect((await store.read())!.state, CheckoutAttemptState.dispatched);
    });
  });

  group('reconcile after a crash', () {
    test('a record still preparing means the order was never sent', () async {
      final coordinator = build();
      final attempt = await coordinator.begin(lines: lines);

      // Process dies here. A new coordinator picks the record up.
      final result = await build().reconcile();

      expect(result.outcome, CheckoutReconcileOutcome.abandoned);
      expect(lookup.lookups, isEmpty,
          reason: 'preparing is provably un-sent; no server round trip needed');
      expect(cart.cartWasCleared, isFalse);
      expect(cart.holdsEnded.single.attemptId, attempt!.attemptId);
      expect(await store.read(), isNull);
    });

    test('a dispatched order found on the server is confirmed and clears',
        () async {
      final coordinator = build();
      final attempt = await coordinator.begin(lines: lines);
      await coordinator.markDispatched(attempt!.attemptId, localRef: 'p1');

      // The POST actually landed; the app died before reading the response.
      lookup.ordersByClientKey[attempt.clientOrderKey] = fakeOrder();

      final result = await build().reconcile();

      expect(result.outcome, CheckoutReconcileOutcome.confirmed);
      expect(result.order!.id, 4821);
      expect(cart.holdsEnded.single.clearCart, isTrue);
      expect(history.resolved, ['p1']);
      expect(await store.read(), isNull);
    });

    test('an unreachable server never concludes the order failed', () async {
      final coordinator = build();
      final attempt = await coordinator.begin(lines: lines);
      await coordinator.markDispatched(attempt!.attemptId);
      lookup.serverReachable = false;

      // Well past the grace window — time alone must not force a verdict.
      now = now.add(const Duration(hours: 2));
      final result = await build().reconcile();

      expect(result.outcome, CheckoutReconcileOutcome.deferred);
      expect(cart.cartWasCleared, isFalse);
      expect((await store.read())!.state, CheckoutAttemptState.unknown,
          reason: 'the record is kept so a later pass can settle it');
    });

    test('no session defers instead of concluding anything', () async {
      final coordinator = build();
      final attempt = await coordinator.begin(lines: lines);
      await coordinator.markDispatched(attempt!.attemptId);
      lookup.canLook = false;

      final result = await build().reconcile();

      expect(result.outcome, CheckoutReconcileOutcome.deferred);
      expect(lookup.lookups, isEmpty);
      expect(await store.read(), isNotNull);
    });

    test('a missing order inside the grace window is not yet failed', () async {
      final coordinator = build();
      final attempt = await coordinator.begin(lines: lines);
      await coordinator.markDispatched(attempt!.attemptId);

      final result = await build().reconcile();

      expect(result.outcome, CheckoutReconcileOutcome.deferred,
          reason: 'WooCommerce may still be writing the order');
      expect(cart.cartWasCleared, isFalse);
      expect((await store.read())!.lookupAttempts, 1);
    });

    test('a missing order past the grace window fails and keeps the cart',
        () async {
      final coordinator = build();
      final attempt = await coordinator.begin(lines: lines);
      await coordinator.markDispatched(attempt!.attemptId, localRef: 'p1');

      now = now.add(CheckoutEngineConfig.reconcileGrace * 2);
      final result = await build().reconcile();

      expect(result.outcome, CheckoutReconcileOutcome.failed);
      expect(cart.cartWasCleared, isFalse,
          reason: 'the whole point: a failed order must not lose the basket');
      expect(history.failed, ['p1']);
      expect(await store.read(), isNull);
    });

    test('an order appearing on a later pass is still confirmed', () async {
      final coordinator = build();
      final attempt = await coordinator.begin(lines: lines);
      await coordinator.markDispatched(attempt!.attemptId);

      lookup.serverReachable = false;
      expect((await build().reconcile()).outcome,
          CheckoutReconcileOutcome.deferred);

      lookup.serverReachable = true;
      lookup.ordersByClientKey[attempt.clientOrderKey] = fakeOrder();

      final result = await build().reconcile();
      expect(result.outcome, CheckoutReconcileOutcome.confirmed);
      expect(cart.holdsEnded.single.clearCart, isTrue);
    });

    test('repeated not-found passes eventually stop probing', () async {
      final coordinator = build();
      final attempt = await coordinator.begin(lines: lines);
      await coordinator.markDispatched(attempt!.attemptId);

      for (var i = 0; i < CheckoutEngineConfig.maxLookupAttempts + 2; i++) {
        await build().reconcile();
      }

      expect(await store.read(), isNull,
          reason: 'a record must not probe forever');
      expect(cart.cartWasCleared, isFalse);
    });

    test('a permanently unreachable store stops blocking new orders', () async {
      final coordinator = build();
      final attempt = await coordinator.begin(lines: lines);
      await coordinator.markDispatched(attempt!.attemptId);
      lookup.serverReachable = false;

      // Probe repeatedly over hours without ever reaching the store.
      for (var i = 0; i < CheckoutEngineConfig.maxLookupAttempts + 2; i++) {
        now = now.add(const Duration(hours: 1));
        await build().reconcile();
      }

      expect(cart.cartWasCleared, isFalse,
          reason: 'the order may exist, but the basket is still the user\'s');
      expect(await store.read(), isNull);

      // The customer is not locked out of ordering again.
      expect(await build().begin(lines: lines), isNotNull);
    });

    test('a stale outstanding attempt does not block a new checkout', () async {
      final coordinator = build();
      final first = await coordinator.begin(lines: lines);
      await coordinator.markDispatched(first!.attemptId);
      await coordinator.markUnknown(first.attemptId, error: 'timeout');

      // Immediately afterwards the guard still holds.
      expect(await build().begin(lines: lines), isNull);

      now = now.add(CheckoutEngineConfig.attemptStaleAfter * 2);
      final second = await build().begin(lines: lines);

      expect(second, isNotNull);
      expect(second!.attemptId, isNot(first.attemptId));
      expect(cart.cartWasCleared, isFalse);
    });

    test('reconcile with no attempt on disk does nothing', () async {
      final result = await build().reconcile();
      expect(result.outcome, CheckoutReconcileOutcome.nothingToDo);
      expect(cart.holdsEnded, isEmpty);
      expect(lookup.lookups, isEmpty);
    });

    test('reconciliation never resubmits — it only ever looks up', () async {
      final coordinator = build();
      final attempt = await coordinator.begin(lines: lines);
      await coordinator.markDispatched(attempt!.attemptId);
      lookup.ordersByClientKey[attempt.clientOrderKey] = fakeOrder();

      await build().reconcile();

      // The coordinator has no submit seam at all; the only server contact it
      // can make is the lookup, and it made exactly one.
      expect(lookup.lookups, [attempt.clientOrderKey]);
    });
  });
}
