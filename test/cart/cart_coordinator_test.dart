import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:Qtoys/config/cart_engine_config.dart';
import 'package:Qtoys/features/cart/data/cart_coordinator.dart';
import 'package:Qtoys/features/cart/data/cart_document_store.dart';
import 'package:Qtoys/features/cart/data/cart_remote_gateway.dart';
import 'package:Qtoys/features/cart/domain/cart_mutation.dart';
import 'package:Qtoys/features/cart/domain/cart_sync_outcome.dart';
import 'package:Qtoys/services/atomic_json_file.dart';
import 'package:Qtoys/services/cart_cache_service.dart' show CartSyncStatus;

import '../support/fake_cart_remote_gateway.dart';

void main() {
  late Directory root;
  late CartDocumentStore store;
  late FakeCartRemoteGateway gateway;
  late DateTime now;
  final recordedDelays = <Duration>[];

  CartCoordinator build({String userKey = 'wp_1'}) => CartCoordinator(
        gateway: gateway,
        userKeyProvider: () async => userKey,
        store: store,
        clock: () => now,
        delay: (d) async => recordedDelays.add(d),
        // Deterministic: tests drive dispatch with flush() instead of racing a
        // real debounce timer.
        autoDispatch: false,
      );

  setUp(() {
    AtomicJsonFile.resetChainsForTest();
    recordedDelays.clear();
    now = DateTime.utc(2026, 7, 31, 12);
    root = Directory.systemTemp.createTempSync('cart_coord');
    store = CartDocumentStore(
      directoryProvider: () async => Directory('${root.path}/cart_cache'),
    );
    gateway = FakeCartRemoteGateway();
  });

  tearDown(() async {
    // Let any writes still on the atomic chain land before removing the dir,
    // then clean up best-effort — a temp dir left behind must never fail a run.
    await pumpEventQueue();
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        if (root.existsSync()) root.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  });

  // ------------------------------------------------------------- coalescing

  group('coalescing', () {
    test('five rapid taps produce one call with the final quantity', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      gateway.resetCalls();

      for (var i = 0; i < 5; i++) {
        await c.add(1);
      }
      expect(c.current.quantityOf(1), 5);

      await c.flush();

      expect(gateway.setQuantityCalls.length, 1,
          reason: 'rapid taps must collapse into a single dispatch');
      expect(gateway.setQuantityCalls.single.targetQuantity, 5);
      expect(gateway.serverCart[1], 5);
      c.dispose();
    });

    test('+++-- lands the final absolute target, never an intermediate', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      gateway.resetCalls();

      await c.add(1);
      await c.add(1);
      await c.add(1);
      await c.setQuantity(1, c.current.quantityOf(1) - 1);
      await c.setQuantity(1, c.current.quantityOf(1) - 1);

      await c.flush();

      expect(gateway.setQuantityCalls.length, 1);
      expect(gateway.setQuantityCalls.single.targetQuantity, 1);
      for (final call in gateway.setQuantityCalls) {
        expect(call.targetQuantity, greaterThanOrEqualTo(0),
            reason: 'a negative target must never be dispatched');
      }
      c.dispose();
    });

    test('add then remove before dispatch results in a single removal', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      gateway.resetCalls();

      await c.add(7);
      await c.remove(7);
      expect(c.current.lines, isEmpty);

      await c.flush();

      expect(gateway.setQuantityCalls.length, 1);
      expect(gateway.setQuantityCalls.single.targetQuantity, 0);
      expect(gateway.serverCart.containsKey(7), isFalse);
      c.dispose();
    });

    test('different products dispatch separately and in order', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      gateway.resetCalls();

      await c.add(1, quantity: 2);
      await c.add(2, quantity: 3);
      await c.flush();

      final calls = gateway.setQuantityCalls;
      expect(calls.length, 2);
      expect(calls[0].productId, 1);
      expect(calls[1].productId, 2);
      expect(gateway.serverCart, {1: 2, 2: 3});
      c.dispose();
    });

    test('the debounce collapses a burst on the real dispatch path', () async {
      // The other coalescing tests use autoDispatch:false, which proves the
      // queue merges but bypasses the debounce that actually ships. This one
      // exercises the shipping path with a delay the test controls.
      final gates = <Completer<void>>[];
      final c = CartCoordinator(
        gateway: gateway,
        userKeyProvider: () async => 'wp_1',
        store: store,
        clock: () => now,
        delay: (_) {
          final gate = Completer<void>();
          gates.add(gate);
          return gate.future;
        },
      );
      await c.start(startHeartbeat: false);
      // Settle startup so the queue is idle before the burst — that is the
      // state the debounce exists for (user opens the cart, then taps +).
      await c.flush();
      await pumpEventQueue();
      for (final gate in gates) {
        if (!gate.isCompleted) gate.complete();
      }
      await pumpEventQueue();
      gates.clear();
      gateway.resetCalls();

      for (var i = 0; i < 5; i++) {
        await c.add(1);
      }
      // Each gesture scheduled a wake-up, but only the newest token is valid.
      expect(gates.length, greaterThanOrEqualTo(5));
      expect(gateway.setQuantityCalls, isEmpty,
          reason: 'an idle queue must not dispatch mid-burst');

      for (final gate in gates) {
        if (!gate.isCompleted) gate.complete();
      }
      await pumpEventQueue();

      expect(gateway.setQuantityCalls.length, 1,
          reason: 'superseded wake-ups must not each dispatch');
      expect(gateway.setQuantityCalls.single.targetQuantity, 5);
      expect(gateway.serverCart[1], 5);
      c.dispose();
    });

    test('clear supersedes everything queued before it', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      await c.add(1, quantity: 2);
      await c.add(2, quantity: 3);
      gateway.resetCalls();

      await c.clear();
      expect(c.current.lines, isEmpty);
      expect(c.current.pending.single.op, CartMutationOp.clearAll);

      await c.flush();
      expect(gateway.calls.where((x) => x.kind == 'clear').length, 1);
      expect(gateway.serverCart, isEmpty);
      c.dispose();
    });
  });

  // ------------------------------------------------------------- persistence

  group('persistence', () {
    test('a mutator only completes once the change is on disk', () async {
      final c = build();
      await c.start(startHeartbeat: false);

      await c.flush();

      await c.add(42, quantity: 3);

      // Read the file directly — no flush, no dispatch.
      final onDisk = await store.read('wp_1');
      expect(onDisk.quantityOf(42), 3,
          reason: 'await add() must imply the write already landed');
      c.dispose();
    });

    test('revision and localSequence advance monotonically', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      final startRev = c.current.revision;
      final startSeq = c.current.localSequence;

      await c.add(1);
      await c.add(2);
      await c.remove(1);

      expect(c.current.revision, startRev + 3);
      expect(c.current.localSequence, greaterThan(startSeq));
      c.dispose();
    });
  });

  // -------------------------------------------------------------- staleness

  group('stale responses', () {
    test('a slow fetch cannot overwrite newer local intent', () async {
      gateway.serverCart[1] = 2;
      gateway.serverKeys[1] = 'key-1';

      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      expect(c.current.quantityOf(1), 2);

      // Hold the fetch open, then make a newer local change.
      final gate = Completer<void>();
      gateway.gate = gate;
      final pendingReconcile = c.reconcile(force: true);
      await Future<void>.delayed(Duration.zero);

      await c.setQuantity(1, 7);
      expect(c.current.quantityOf(1), 7);

      // Now let the older response (which still says 2) land.
      gate.complete();
      gateway.gate = null;
      await pendingReconcile;

      expect(c.current.quantityOf(1), 7,
          reason: 'newer local intent must survive an older server response');
      expect(c.current.confirmed!.lines.single.quantity, 2,
          reason: 'the server view is still recorded, just not adopted');
      c.dispose();
    });

    test('the server view is adopted when there is no competing intent', () async {
      // Simulates the cart being edited on the website.
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      gateway.serverCart[9] = 4;
      gateway.serverKeys[9] = 'key-9';

      final outcome = await c.reconcile(force: true);

      expect(outcome, isA<CartSyncSucceeded>());
      expect(c.current.quantityOf(9), 4);
      c.dispose();
    });

    test('line keys from the server are used on the next dispatch', () async {
      gateway.serverCart[5] = 1;
      gateway.serverKeys[5] = 'key-5';

      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      await c.reconcile(force: true);
      gateway.resetCalls();

      await c.setQuantity(5, 3);
      await c.flush();

      expect(gateway.setQuantityCalls.single.knownKey, 'key-5',
          reason: 'avoids an extra GET /cart/items round trip');
      c.dispose();
    });
  });

  // ------------------------------------------------------------- reconcile

  group('reconcile outcomes', () {
    test('an empty cart is a success, not a failure', () async {
      final c = build();
      await c.start(startHeartbeat: false);

      await c.flush();

      final outcome = await c.reconcile(force: true);

      expect(outcome, isA<CartSyncSucceeded>());
      expect((outcome as CartSyncSucceeded).isEmptyCart, isTrue);
      c.dispose();
    });

    test('a guest reconcile is skipped, not failed', () async {
      gateway.signedIn = false;
      final c = build();
      await c.start(startHeartbeat: false);

      await c.flush();

      final outcome = await c.reconcile(force: true);

      expect(outcome, isA<CartSyncSkipped>());
      expect((outcome as CartSyncSkipped).reason, CartSyncSkipReason.guest);
      c.dispose();
    });

    test('a concurrent reconcile is skipped, not failed', () async {
      final c = build();
      await c.start(startHeartbeat: false);

      await c.flush();

      final gate = Completer<void>();
      gateway.gate = gate;
      final first = c.reconcile(force: true);
      await Future<void>.delayed(Duration.zero);

      final second = await c.reconcile(force: true);
      expect(second, isA<CartSyncSkipped>());
      expect((second as CartSyncSkipped).reason,
          CartSyncSkipReason.alreadyInFlight);

      gate.complete();
      gateway.gate = null;
      expect(await first, isA<CartSyncSucceeded>());
      c.dispose();
    });

    test('a failed fetch reports a friendly message and keeps the basket', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      await c.add(3, quantity: 2);

      gateway.scriptedFetch.add(
        const GatewayResult.transientFailure('SocketException: refused'),
      );
      final outcome = await c.reconcile(force: true);

      expect(outcome, isA<CartSyncFailed>());
      final failed = outcome as CartSyncFailed;
      expect(failed.userMessage, isNot(contains('Socket')));
      expect(failed.debugDetail, contains('SocketException'));
      expect(c.current.quantityOf(3), 2, reason: 'local basket is preserved');
      c.dispose();
    });
  });

  // ------------------------------------------------------- failure handling

  group('failure handling', () {
    test('transient failures back off on the documented schedule', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      gateway.resetCalls();

      await c.add(1);
      for (var attempt = 0; attempt < 3; attempt++) {
        gateway.scriptedSetQuantity
            .add(const GatewayResult.transientFailure('timeout'));
        await c.flush();
        now = now.add(const Duration(minutes: 1)); // let the backoff elapse
      }

      final m = c.current.pending.single;
      expect(m.retryCount, 3);
      expect(m.state, CartMutationState.queued);
      expect(c.current.quantityOf(1), 1, reason: 'intent is untouched');
      c.dispose();
    });

    test('the retry budget is bounded and then the mutation parks', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      await c.add(1);

      for (var attempt = 0; attempt < CartEngineConfig.maxAttempts; attempt++) {
        gateway.scriptedSetQuantity
            .add(const GatewayResult.transientFailure('timeout'));
        await c.flush();
        now = now.add(const Duration(minutes: 1));
      }

      expect(c.current.pending.single.state,
          CartMutationState.failedPermanent);
      expect(c.current.hasPendingWork, isFalse);
      c.dispose();
    });

    test('a permanent failure parks after one attempt', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      gateway.resetCalls();

      await c.add(1);
      gateway.scriptedSetQuantity
          .add(const GatewayResult.permanentFailure('out of stock'));
      await c.flush();

      expect(gateway.setQuantityCalls.length, 1,
          reason: 'no retry loop on a validation error');
      expect(c.current.pending.single.state,
          CartMutationState.failedPermanent);
      c.dispose();
    });

    test('one failed product does not block another', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      gateway.resetCalls();

      await c.add(1);
      await c.add(2);
      gateway.scriptedSetQuantity
          .add(const GatewayResult.permanentFailure('out of stock'));
      await c.flush();

      expect(gateway.serverCart[2], 1,
          reason: 'the second product still dispatched');
      c.dispose();
    });

    test('a fresh gesture supersedes a permanently failed mutation', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      await c.add(1);
      gateway.scriptedSetQuantity
          .add(const GatewayResult.permanentFailure('out of stock'));
      await c.flush();
      expect(c.current.pending.single.state,
          CartMutationState.failedPermanent);

      await c.setQuantity(1, 4);
      expect(c.current.pending.single.state, CartMutationState.queued);
      await c.flush();
      expect(gateway.serverCart[1], 4);
      c.dispose();
    });
  });

  // ----------------------------------------------------- idempotent replay

  group('ambiguous timeout', () {
    test('a retry after a timeout that actually applied does not double', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      gateway.resetCalls();

      await c.add(1, quantity: 3);

      // The server applies the change, then the response is lost.
      gateway.applyThenFail = true;
      gateway.scriptedSetQuantity
          .add(const GatewayResult.transientFailure('timeout'));
      await c.flush();
      expect(gateway.serverCart[1], 3, reason: 'it did land server-side');

      // Retry the same logical mutation.
      gateway.applyThenFail = false;
      now = now.add(const Duration(minutes: 1));
      await c.flush();

      expect(gateway.serverCart[1], 3,
          reason: 'absolute targets converge; increments would give 6');
      c.dispose();
    });

    test('the idempotency key is stable across retries', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      await c.add(1);
      final keyBefore = c.current.pending.single.idempotencyKey;

      gateway.scriptedSetQuantity
          .add(const GatewayResult.transientFailure('timeout'));
      await c.flush();

      expect(c.current.pending.single.idempotencyKey, keyBefore);
      c.dispose();
    });
  });

  // ------------------------------------------------------------- restart

  group('restart', () {
    test('pending mutations replay after a restart', () async {
      final a = build();
      await a.start(startHeartbeat: false);
      await a.flush();
      await a.add(1, quantity: 2);
      await a.add(2, quantity: 5);
      expect(a.current.hasPendingWork, isTrue);
      a.dispose(); // simulate process death before dispatch

      expect(gateway.serverCart, isEmpty);

      final b = build();
      await b.start(startHeartbeat: false);
      await b.flush();

      expect(b.current.quantityOf(1), 2);
      expect(gateway.serverCart, {1: 2, 2: 5});
      b.dispose();
    });

    test('replaying a mutation the server already applied is a no-op', () async {
      final a = build();
      await a.start(startHeartbeat: false);
      await a.flush();
      await a.add(1, quantity: 4);
      a.dispose();

      // The server had in fact applied it before the crash.
      gateway.serverCart[1] = 4;
      gateway.serverKeys[1] = 'key-1';

      final b = build();
      await b.start(startHeartbeat: false);
      await b.flush();

      expect(gateway.serverCart[1], 4, reason: 'converges, does not stack');
      b.dispose();
    });

    test('an in-flight mutation is resumed rather than lost', () async {
      final a = build();
      await a.start(startHeartbeat: false);
      await a.flush();
      await a.add(1, quantity: 2);
      // Force the on-disk state to look like a crash mid-dispatch.
      final doc = await store.read('wp_1');
      await store.write(doc.copyWith(
        pending: [doc.pending.single.copyWith(state: CartMutationState.inFlight)],
      ));
      a.dispose();

      final b = build();
      await b.start(startHeartbeat: false);
      // Assert the demotion before draining, otherwise the queue is empty.
      expect(b.current.pending.single.state, CartMutationState.queued,
          reason: 'a crash mid-dispatch must be replayable, not stranded');

      await b.flush();
      expect(gateway.serverCart[1], 2);
      b.dispose();
    });
  });

  // --------------------------------------------------------- guest adoption

  group('guest cart adoption', () {
    test('adopting twice does not double the basket', () async {
      final c = build();
      await c.start(startHeartbeat: false);

      await c.flush();

      await c.adoptCart({1: 2, 2: 1});
      await c.adoptCart({1: 2, 2: 1});

      expect(c.current.quantityOf(1), 2,
          reason: 'adoption takes the larger value, it does not sum');
      expect(c.current.quantityOf(2), 1);
      c.dispose();
    });

    test('adoption is local and needs no network to complete', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      gateway.resetCalls();

      await c.adoptCart({1: 3});

      expect(c.current.quantityOf(1), 3);
      expect(gateway.setQuantityCalls, isEmpty,
          reason: 'login must not block on cart sync');
      c.dispose();
    });
  });

  // ------------------------------------------------------------- reorder

  group('setExactLines (reorder)', () {
    test('reordering an item already in the cart does not double it', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      await c.add(1, quantity: 2);
      await c.flush();

      // Reorder asks for 2 of the same product.
      await c.setExactLines({1: 2});
      await c.flush();

      expect(c.current.quantityOf(1), 2,
          reason: 'absolute targets; the old add() path produced 4');
      expect(gateway.serverCart[1], 2);
      c.dispose();
    });

    test('lines absent from the target are removed', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      await c.add(1, quantity: 1);
      await c.add(2, quantity: 1);
      await c.flush();

      await c.setExactLines({1: 3});
      await c.flush();

      expect(c.current.quantityOf(1), 3);
      expect(c.current.quantityOf(2), 0);
      expect(gateway.serverCart, {1: 3});
      c.dispose();
    });
  });

  // -------------------------------------------------------- checkout hold

  group('checkout hold', () {
    test('a hold blocks mutations so the basket cannot shift mid-order', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      await c.add(1, quantity: 2);

      await c.beginCheckoutHold('attempt-1');
      await c.add(1, quantity: 5);

      expect(c.current.quantityOf(1), 2, reason: 'mutation refused under hold');
      c.dispose();
    });

    test('releasing the hold restores mutability', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      await c.beginCheckoutHold('attempt-1');
      await c.endCheckoutHold('attempt-1', clearCart: false);

      await c.add(1, quantity: 2);
      expect(c.current.quantityOf(1), 2);
      c.dispose();
    });

    test('a leaked hold expires instead of freezing the cart forever', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      await c.beginCheckoutHold('attempt-1');

      // Nobody ever released it; time passes beyond the TTL.
      now = now.add(CartEngineConfig.checkoutHoldTtl * 2);

      await c.add(1, quantity: 2);
      expect(c.current.quantityOf(1), 2,
          reason: 'the TTL must prevent a permanent freeze');
      c.dispose();
    });

    test('clearing on confirmation empties the basket', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      await c.add(1, quantity: 2);
      await c.beginCheckoutHold('attempt-1');

      await c.endCheckoutHold('attempt-1', clearCart: true);

      expect(c.current.lines, isEmpty);
      expect(c.current.syncStatus, CartSyncStatus.synced);
      c.dispose();
    });
  });

  // ------------------------------------------------------- checkout barrier

  group('drainForCheckout', () {
    test('returns true once the queue is empty', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      await c.add(1, quantity: 2);

      expect(await c.drainForCheckout(), isTrue);
      expect(gateway.serverCart[1], 2);
      c.dispose();
    });

    test('returns false while work is still outstanding', () async {
      final c = build();
      await c.start(startHeartbeat: false);
      await c.flush();
      await c.add(1, quantity: 2);

      // Every attempt fails transiently, so the queue never drains.
      for (var i = 0; i < 10; i++) {
        gateway.scriptedSetQuantity
            .add(const GatewayResult.transientFailure('timeout'));
      }

      expect(await c.drainForCheckout(timeout: Duration.zero), isFalse);
      c.dispose();
    });
  });

  // ------------------------------------------------------------- streaming

  test('the document stream emits on every accepted change', () async {
    final c = build();
    await c.start(startHeartbeat: false);

    await c.flush();

    final seen = <int>[];
    final sub = c.stream.listen((d) => seen.add(d.totalQuantity));

    await c.add(1, quantity: 2);
    await c.add(1, quantity: 3);
    await c.remove(1);
    await Future<void>.delayed(Duration.zero);

    expect(seen, containsAllInOrder([2, 5, 0]));
    await sub.cancel();
    c.dispose();
  });
}
