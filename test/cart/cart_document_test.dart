import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:Qtoys/features/cart/domain/cart_document.dart';
import 'package:Qtoys/features/cart/domain/cart_item.dart';
import 'package:Qtoys/features/cart/domain/cart_mutation.dart';
import 'package:Qtoys/services/cart_cache_service.dart' show CartSyncStatus;

CartMutation _mutation({
  int productId = 10,
  int target = 3,
  int seq = 1,
  CartMutationState state = CartMutationState.queued,
  int retries = 0,
}) {
  return CartMutation(
    mutationId: 'm$seq',
    localSequence: seq,
    cartRevision: seq,
    op: CartMutationOp.setQuantity,
    productId: productId,
    targetQuantity: target,
    createdAt: DateTime.utc(2026, 7, 31, 12),
    retryCount: retries,
    state: state,
  );
}

/// Round-trips a document through JSON exactly as the store does.
CartDocument _roundTrip(CartDocument doc) => CartDocument.fromJson(
      jsonDecode(jsonEncode(doc.toJson())) as Map<String, dynamic>,
      doc.userKey,
    );

void main() {
  group('CartDocument round-trip', () {
    test('preserves every field', () {
      final doc = CartDocument(
        userKey: 'wp_7',
        revision: 12,
        localSequence: 34,
        lines: const [
          CartLine(productId: 1, quantity: 2, lastLocalSeq: 30),
          CartLine(productId: 5, quantity: 9, lastLocalSeq: 34),
        ],
        confirmed: ConfirmedCart(
          lines: const [CartItem(productId: 1, quantity: 2)],
          snapshotJson: const {'items_count': 2, 'totals': {'total_price': '900'}},
          cartItemKeyByProductId: const {1: 'abc123', 5: 'def456'},
          fetchedAt: DateTime.utc(2026, 7, 31, 11),
        ),
        pending: [_mutation(seq: 34, productId: 5, target: 9)],
        syncStatus: CartSyncStatus.pending,
        lastSyncError: 'friendly message',
        checkoutHoldId: 'attempt-1',
        checkoutHoldAt: DateTime.utc(2026, 7, 31, 12),
        updatedAt: DateTime.utc(2026, 7, 31, 12),
      );

      final back = _roundTrip(doc);

      expect(back.userKey, 'wp_7');
      expect(back.revision, 12);
      expect(back.localSequence, 34);
      expect(back.lines.map((l) => l.productId), [1, 5]);
      expect(back.lines[1].quantity, 9);
      expect(back.lines[1].lastLocalSeq, 34);
      expect(back.confirmed!.cartItemKeyByProductId[5], 'def456');
      expect(back.confirmed!.snapshotJson!['items_count'], 2);
      expect(back.confirmed!.fetchedAt, DateTime.utc(2026, 7, 31, 11));
      expect(back.pending.single.targetQuantity, 9);
      expect(back.lastSyncError, 'friendly message');
      expect(back.checkoutHoldId, 'attempt-1');
    });

    test('never persists the transient syncing status', () {
      const doc = CartDocument(
        userKey: 'g',
        syncStatus: CartSyncStatus.syncing,
        lines: [CartLine(productId: 1, quantity: 1)],
      );
      expect(doc.toJson()['syncStatus'], 'pending');
      expect(_roundTrip(doc).syncStatus, CartSyncStatus.pending);
    });

    test('an old file carrying syncing is normalised on read', () {
      final doc = CartDocument.fromJson({
        'schemaVersion': 2,
        'userKey': 'g',
        'syncStatus': 'syncing',
        'lines': <dynamic>[],
      }, 'g');
      expect(doc.syncStatus, CartSyncStatus.pending);
    });

    test('pending mutations are ordered by local sequence', () {
      final doc = CartDocument(
        userKey: 'g',
        pending: [_mutation(seq: 9), _mutation(seq: 2), _mutation(seq: 5)],
      );
      expect(_roundTrip(doc).pending.map((m) => m.localSequence), [2, 5, 9]);
    });

    test('an in-flight mutation is demoted to queued so it replays', () {
      // The process may have died mid-dispatch. Replay is safe because targets
      // are absolute, so re-sending converges instead of accumulating.
      final doc = CartDocument(
        userKey: 'g',
        pending: [_mutation(state: CartMutationState.inFlight, retries: 2)],
      );
      final back = _roundTrip(doc);
      expect(back.pending.single.state, CartMutationState.queued);
      expect(back.pending.single.retryCount, 2, reason: 'retries carry over');
    });

    test('a permanently failed mutation stays failed', () {
      final doc = CartDocument(
        userKey: 'g',
        pending: [_mutation(state: CartMutationState.failedPermanent)],
      );
      expect(_roundTrip(doc).pending.single.state,
          CartMutationState.failedPermanent);
    });
  });

  group('v1 migration', () {
    test('carries items and the last snapshot forward', () {
      // Exactly the legacy CartCacheRecord shape.
      final v1 = {
        'version': 1,
        'updatedAt': '2026-07-30T10:00:00.000Z',
        'lastSyncAt': '2026-07-30T09:00:00.000Z',
        'syncStatus': 'synced',
        'items': [
          {'productId': 11, 'quantity': 2},
          {'productId': 12, 'quantity': 1},
        ],
        'snapshot': {'items_count': 3, 'totals': <String, dynamic>{}},
      };

      final doc = CartDocument.fromJson(v1, 'wp_9');

      expect(doc.userKey, 'wp_9');
      expect(doc.lines.map((l) => l.productId), [11, 12]);
      expect(doc.lines.first.quantity, 2);
      expect(doc.lines.first.lastLocalSeq, 0);
      expect(doc.confirmed!.snapshotJson!['items_count'], 3);
      expect(doc.confirmed!.lines.length, 2);
      expect(doc.pending, isEmpty, reason: 'v1 had no mutation queue');
      expect(doc.syncStatus, CartSyncStatus.synced);
    });

    test('drops invalid legacy lines without discarding the rest', () {
      final doc = CartDocument.fromJson({
        'version': 1,
        'items': [
          {'productId': 11, 'quantity': 2},
          {'productId': 0, 'quantity': 5},
          {'productId': 13, 'quantity': 0},
          'not a map',
        ],
      }, 'g');
      expect(doc.lines.map((l) => l.productId), [11]);
    });
  });

  group('corrupt input', () {
    test('an empty map yields an empty document, not an exception', () {
      final doc = CartDocument.fromJson(<String, dynamic>{}, 'g');
      expect(doc.lines, isEmpty);
      expect(doc.userKey, 'g');
      expect(doc.revision, 0);
    });

    test('garbage field types are coerced rather than thrown on', () {
      final doc = CartDocument.fromJson({
        'schemaVersion': 2,
        'revision': 'not a number',
        'lines': 'not a list',
        'pending': 42,
        'confirmed': 'nope',
      }, 'g');
      expect(doc.revision, 0);
      expect(doc.lines, isEmpty);
      expect(doc.pending, isEmpty);
      expect(doc.confirmed, isNull);
    });
  });

  group('query helpers', () {
    final doc = CartDocument(
      userKey: 'g',
      lines: const [
        CartLine(productId: 1, quantity: 2),
        CartLine(productId: 2, quantity: 3),
      ],
      pending: [_mutation(productId: 2, seq: 1)],
    );

    test('quantityOf and totalQuantity', () {
      expect(doc.quantityOf(1), 2);
      expect(doc.quantityOf(999), 0);
      expect(doc.totalQuantity, 5);
    });

    test('hasPendingFor tracks the queue per product', () {
      expect(doc.hasPendingFor(2), isTrue);
      expect(doc.hasPendingFor(1), isFalse);
    });

    test('a clearAll mutation counts as pending for every product', () {
      final clearing = CartDocument(
        userKey: 'g',
        lines: doc.lines,
        pending: [
          CartMutation(
            mutationId: 'c1',
            localSequence: 4,
            cartRevision: 4,
            op: CartMutationOp.clearAll,
            productId: 0,
            targetQuantity: 0,
            createdAt: DateTime.utc(2026),
          ),
        ],
      );
      expect(clearing.hasPendingFor(1), isTrue);
      expect(clearing.hasPendingFor(2), isTrue);
    });

    test('failed mutations do not count as pending work', () {
      final failed = CartDocument(
        userKey: 'g',
        pending: [_mutation(state: CartMutationState.failedPermanent)],
      );
      expect(failed.hasPendingWork, isFalse);
      expect(failed.hasPendingFor(10), isFalse);
    });
  });

  group('checkout hold TTL', () {
    const ttl = Duration(minutes: 3);
    final now = DateTime.utc(2026, 7, 31, 12);

    test('no hold is inactive', () {
      expect(const CartDocument(userKey: 'g').holdIsActive(ttl, now), isFalse);
    });

    test('a fresh hold is active', () {
      final doc = CartDocument(
        userKey: 'g',
        checkoutHoldId: 'a1',
        checkoutHoldAt: now.subtract(const Duration(seconds: 30)),
      );
      expect(doc.holdIsActive(ttl, now), isTrue);
    });

    test('a leaked hold expires so the cart cannot freeze forever', () {
      final doc = CartDocument(
        userKey: 'g',
        checkoutHoldId: 'a1',
        checkoutHoldAt: now.subtract(const Duration(minutes: 5)),
      );
      expect(doc.holdIsActive(ttl, now), isFalse);
    });
  });

  group('CartMutation', () {
    test('ids are unique across rapid creation', () {
      final ids = {for (var i = 0; i < 500; i++) CartMutation.newMutationId()};
      expect(ids.length, 500);
    });

    test('isReady respects the backoff timestamp', () {
      final now = DateTime.utc(2026, 7, 31, 12);
      final waiting = _mutation().copyWith(
        nextAttemptAt: now.add(const Duration(seconds: 5)),
      );
      expect(waiting.isReady(now), isFalse);
      expect(waiting.isReady(now.add(const Duration(seconds: 6))), isTrue);
    });

    test('a permanently failed mutation is never ready', () {
      final dead = _mutation(state: CartMutationState.failedPermanent);
      expect(dead.isReady(DateTime.utc(2030)), isFalse);
    });

    test('the idempotency key is stable across retries', () {
      final m = _mutation();
      final retried = m.copyWith(retryCount: 3);
      expect(retried.idempotencyKey, m.idempotencyKey);
    });
  });
}
