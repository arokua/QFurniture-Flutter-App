import 'package:flutter_test/flutter_test.dart';
import 'package:Qtoys/features/cart/domain/cart_item.dart';
import 'package:Qtoys/features/cart/domain/cart_sync_outcome.dart';
import 'package:Qtoys/services/cart_cache_service.dart';

/// Pins the contract that the "empty cart shows a red error" bug violated.
///
/// Before this type existed, `syncNow` returned `CartCacheRecord?` and every
/// caller read `null` as failure — so "cart is empty", "a sync was already
/// running" and "the request failed" were indistinguishable.
void main() {
  const emptyRecord = CartCacheRecord(items: []);
  const filledRecord = CartCacheRecord(
    items: [CartItem(productId: 1, quantity: 2)],
  );

  group('CartSyncSucceeded', () {
    test('an empty cart is a success, not a failure', () {
      const outcome = CartSyncSucceeded(emptyRecord);
      expect(outcome, isA<CartSyncSucceeded>());
      expect(outcome, isNot(isA<CartSyncFailed>()));
      expect(outcome.isEmptyCart, isTrue);
      expect(outcome.record.items, isEmpty);
    });

    test('carries the record for a non-empty cart', () {
      const outcome = CartSyncSucceeded(filledRecord);
      expect(outcome.isEmptyCart, isFalse);
      expect(outcome.record.items.single.productId, 1);
    });
  });

  group('CartSyncSkipped', () {
    test('is not a failure and preserves the last cached record', () {
      const outcome = CartSyncSkipped(
        CartSyncSkipReason.alreadyInFlight,
        filledRecord,
      );
      expect(outcome, isNot(isA<CartSyncFailed>()));
      expect(outcome, isNot(isA<CartSyncSucceeded>()));
      expect(outcome.record, same(filledRecord));
      expect(outcome.reason, CartSyncSkipReason.alreadyInFlight);
    });

    test('a guest skip carries no failure message', () {
      const outcome = CartSyncSkipped(CartSyncSkipReason.guest);
      expect(outcome.reason, CartSyncSkipReason.guest);
      expect(outcome.record, isNull);
    });
  });

  group('CartSyncFailed', () {
    test('user message is friendly and free of technical jargon', () {
      const outcome = CartSyncFailed(
        userMessage: "We're having trouble reaching our cart server.",
        debugDetail: 'SocketException: Connection timed out',
      );
      expect(outcome.userMessage, isNot(contains('Exception')));
      expect(outcome.userMessage, isNot(contains('Socket')));
      expect(outcome.userMessage, isNot(contains('null')));
      // Raw detail stays available for debug builds only.
      expect(outcome.debugDetail, contains('SocketException'));
      expect(outcome.transient, isTrue);
    });
  });

  test('the three outcomes are mutually exclusive', () {
    final outcomes = <CartSyncOutcome>[
      const CartSyncSucceeded(emptyRecord),
      const CartSyncSkipped(CartSyncSkipReason.throttled),
      const CartSyncFailed(userMessage: 'x'),
    ];
    for (final o in outcomes) {
      final matches = [
        o is CartSyncSucceeded,
        o is CartSyncSkipped,
        o is CartSyncFailed,
      ].where((m) => m).length;
      expect(matches, 1, reason: '$o must match exactly one case');
    }
  });
}
