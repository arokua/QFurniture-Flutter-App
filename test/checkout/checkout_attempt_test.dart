import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:Qtoys/features/checkout/data/checkout_attempt_store.dart';
import 'package:Qtoys/features/checkout/domain/checkout_attempt.dart';
import 'package:Qtoys/services/atomic_json_file.dart';

void main() {
  group('CheckoutAttempt', () {
    final created = DateTime.utc(2026, 8, 1, 12);

    CheckoutAttempt attempt({
      CheckoutAttemptState state = CheckoutAttemptState.preparing,
    }) =>
        CheckoutAttempt(
          attemptId: 'qco_1',
          clientOrderKey: 'qco_1',
          userKey: 'wp_7',
          state: state,
          lines: const [CheckoutAttemptLine(productId: 11, quantity: 3)],
          createdAt: created,
        );

    test('only preparing is abandonable', () {
      expect(attempt().isAbandonable, isTrue);
      for (final s in CheckoutAttemptState.values
          .where((s) => s != CheckoutAttemptState.preparing)) {
        expect(attempt(state: s).isAbandonable, isFalse, reason: s.name);
      }
    });

    test('dispatched and unknown are the states needing reconciliation', () {
      expect(
        CheckoutAttemptState.values
            .where((s) => attempt(state: s).needsReconciliation)
            .toSet(),
        {CheckoutAttemptState.dispatched, CheckoutAttemptState.unknown},
      );
    });

    test('confirmed and failed are terminal', () {
      expect(
        CheckoutAttemptState.values
            .where((s) => attempt(state: s).isTerminal)
            .toSet(),
        {CheckoutAttemptState.confirmed, CheckoutAttemptState.failed},
      );
    });

    test('age is measured from dispatch once dispatched', () {
      final a = attempt(state: CheckoutAttemptState.dispatched).copyWith(
        dispatchedAt: created.add(const Duration(minutes: 10)),
      );
      // Two minutes after creation but before dispatch + grace.
      expect(
        a.isOlderThan(
          const Duration(minutes: 5),
          created.add(const Duration(minutes: 12)),
        ),
        isFalse,
      );
      expect(
        a.isOlderThan(
          const Duration(minutes: 5),
          created.add(const Duration(minutes: 16)),
        ),
        isTrue,
      );
    });

    test('json round trip preserves every field that drives a decision', () {
      final original = attempt(state: CheckoutAttemptState.dispatched).copyWith(
        dispatchedAt: created.add(const Duration(seconds: 3)),
        localRef: 'pending_1',
        totalDisplay: r'$1,284.00',
        lookupAttempts: 2,
        drainSettled: false,
      );

      final decoded = CheckoutAttempt.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      )!;

      expect(decoded.attemptId, original.attemptId);
      expect(decoded.clientOrderKey, original.clientOrderKey);
      expect(decoded.userKey, 'wp_7');
      expect(decoded.state, CheckoutAttemptState.dispatched);
      expect(decoded.dispatchedAt, original.dispatchedAt);
      expect(decoded.localRef, 'pending_1');
      expect(decoded.lookupAttempts, 2);
      expect(decoded.drainSettled, isFalse);
      expect(decoded.quantityByProductId, {11: 3});
      expect(decoded.totalQuantity, 3);
    });

    test('an unrecognised state decodes as unknown, never as confirmed', () {
      final decoded = CheckoutAttempt.fromJson({
        'attemptId': 'qco_1',
        'createdAt': created.toIso8601String(),
        'state': 'something_from_a_future_build',
      });
      expect(decoded!.state, CheckoutAttemptState.unknown,
          reason: 'guessing confirmed would clear a basket for a phantom order');
    });

    test('a record without an id or a date is rejected rather than guessed', () {
      expect(CheckoutAttempt.fromJson({'createdAt': '2026-08-01'}), isNull);
      expect(CheckoutAttempt.fromJson({'attemptId': 'qco_1'}), isNull);
    });

    test('generated attempt ids are unique', () {
      final ids = {for (var i = 0; i < 500; i++) CheckoutAttempt.newAttemptId()};
      expect(ids, hasLength(500));
    });
  });

  group('CheckoutAttemptStore', () {
    late Directory root;
    late CheckoutAttemptStore store;

    setUp(() {
      AtomicJsonFile.resetChainsForTest();
      root = Directory.systemTemp.createTempSync('checkout_store');
      store = CheckoutAttemptStore(
        directoryProvider: () async => Directory('${root.path}/checkout_state'),
      );
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('reading before anything is written yields null', () async {
      expect(await store.read(), isNull);
    });

    test('write then read round trips through disk', () async {
      final attempt = CheckoutAttempt.starting(
        userKey: 'wp_7',
        lines: const [CheckoutAttemptLine(productId: 11, quantity: 3)],
        now: DateTime.utc(2026, 8, 1, 12),
      );
      await store.write(attempt);

      final read = await store.read();
      expect(read!.attemptId, attempt.attemptId);
      expect(read.state, CheckoutAttemptState.preparing);
    });

    test('a corrupt file reads as no attempt rather than throwing', () async {
      final f = await store.file();
      await f.writeAsString('{not json at all');
      expect(await store.read(), isNull);
    });

    test('clear removes the record', () async {
      await store.write(CheckoutAttempt.starting(
        userKey: 'wp_7',
        lines: const [CheckoutAttemptLine(productId: 11, quantity: 3)],
        now: DateTime.utc(2026, 8, 1, 12),
      ));
      await store.clear();
      expect(await store.read(), isNull);
    });
  });
}
