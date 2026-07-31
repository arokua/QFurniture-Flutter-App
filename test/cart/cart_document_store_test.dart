import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:Qtoys/features/cart/data/cart_document_store.dart';
import 'package:Qtoys/features/cart/domain/cart_document.dart';
import 'package:Qtoys/features/cart/domain/cart_item.dart';
import 'package:Qtoys/features/cart/domain/cart_mutation.dart';
import 'package:Qtoys/services/atomic_json_file.dart';
import 'package:Qtoys/services/cart_cache_service.dart' show CartSyncStatus;

void main() {
  late Directory root;
  late CartDocumentStore store;

  setUp(() {
    AtomicJsonFile.resetChainsForTest();
    root = Directory.systemTemp.createTempSync('cart_doc_store');
    store = CartDocumentStore(
      directoryProvider: () async => Directory('${root.path}/cart_cache'),
    );
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('reading a key that was never written yields an empty document', () async {
    final doc = await store.read('wp_1');
    expect(doc.userKey, 'wp_1');
    expect(doc.lines, isEmpty);
    expect(doc.revision, 0);
  });

  test('write then read preserves intent, confirmed view and queue', () async {
    final doc = CartDocument(
      userKey: 'wp_1',
      revision: 4,
      localSequence: 9,
      lines: const [CartLine(productId: 3, quantity: 7, lastLocalSeq: 9)],
      confirmed: ConfirmedCart(
        lines: const [CartItem(productId: 3, quantity: 5)],
        snapshotJson: const {'items_count': 5},
        cartItemKeyByProductId: const {3: 'key-abc'},
        fetchedAt: DateTime.utc(2026, 7, 31, 10),
      ),
      pending: [
        CartMutation(
          mutationId: 'm1',
          localSequence: 9,
          cartRevision: 4,
          op: CartMutationOp.setQuantity,
          productId: 3,
          targetQuantity: 7,
          createdAt: DateTime.utc(2026, 7, 31, 10, 30),
        ),
      ],
      syncStatus: CartSyncStatus.pending,
    );

    await store.write(doc);
    final back = await store.read('wp_1');

    expect(back.revision, 4);
    expect(back.localSequence, 9);
    expect(back.lines.single.quantity, 7);
    // Intent (7) and the server view (5) stay separate — merging them is what
    // let a slow GET overwrite a newer local change.
    expect(back.confirmed!.lines.single.quantity, 5);
    expect(back.confirmed!.cartItemKeyByProductId[3], 'key-abc');
    expect(back.pending.single.targetQuantity, 7);
  });

  test('writing stamps updatedAt', () async {
    await store.write(const CartDocument(userKey: 'wp_1'));
    final back = await store.read('wp_1');
    expect(back.updatedAt, isNotNull);
  });

  test('separate user keys do not collide', () async {
    await store.write(const CartDocument(
      userKey: 'wp_1',
      lines: [CartLine(productId: 1, quantity: 1)],
    ));
    await store.write(const CartDocument(
      userKey: 'guest',
      lines: [CartLine(productId: 2, quantity: 2)],
    ));

    expect((await store.read('wp_1')).lines.single.productId, 1);
    expect((await store.read('guest')).lines.single.productId, 2);
  });

  test('unsafe characters in a user key are sanitised into the filename', () async {
    const key = 'email_a/b\\c:d';
    await store.write(const CartDocument(
      userKey: key,
      lines: [CartLine(productId: 5, quantity: 1)],
    ));
    final back = await store.read(key);
    expect(back.lines.single.productId, 5);

    final file = await store.fileFor(key);
    expect(file.path, isNot(contains('/b')));
    expect(file.existsSync(), isTrue);
  });

  test('a corrupt file degrades to empty instead of throwing', () async {
    final file = await store.fileFor('wp_1');
    file.writeAsStringSync('{ this is not json');

    final doc = await store.read('wp_1');
    expect(doc.lines, isEmpty);
    expect(doc.userKey, 'wp_1');
    // The bad file is left on disk; the next write replaces it atomically.
    expect(file.existsSync(), isTrue);
  });

  test('an empty file degrades to empty', () async {
    final file = await store.fileFor('wp_1');
    file.writeAsStringSync('   ');
    expect((await store.read('wp_1')).lines, isEmpty);
  });

  test('a legacy v1 cache file migrates and keeps the basket', () async {
    // Exactly what CartCacheService used to write.
    final file = await store.fileFor('wp_1');
    file.writeAsStringSync(jsonEncode({
      'version': 1,
      'updatedAt': '2026-07-30T10:00:00.000Z',
      'lastSyncAt': '2026-07-30T09:00:00.000Z',
      'syncStatus': 'synced',
      'items': [
        {'productId': 11, 'quantity': 2},
        {'productId': 12, 'quantity': 1},
      ],
      'snapshot': {'items_count': 3},
    }));

    final doc = await store.read('wp_1');
    expect(doc.lines.map((l) => l.productId), [11, 12]);
    expect(doc.confirmed!.snapshotJson!['items_count'], 3);
    expect(doc.pending, isEmpty);
  });

  test('a migrated document rewrites as v2', () async {
    final file = await store.fileFor('wp_1');
    file.writeAsStringSync(jsonEncode({
      'version': 1,
      'items': [
        {'productId': 11, 'quantity': 2}
      ],
    }));

    await store.write(await store.read('wp_1'));

    final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(raw['schemaVersion'], CartDocument.schemaVersion);
    expect(raw['lines'], isA<List>());
  });

  test('concurrent writes leave a single parseable document', () async {
    await Future.wait([
      for (var i = 1; i <= 25; i++)
        store.write(CartDocument(
          userKey: 'wp_1',
          revision: i,
          lines: [CartLine(productId: 1, quantity: i)],
        )),
    ]);

    final back = await store.read('wp_1');
    expect(back.revision, 25);
    expect(back.lines.single.quantity, 25);
  });

  test('delete removes one key and leaves the others', () async {
    await store.write(const CartDocument(
      userKey: 'wp_1',
      lines: [CartLine(productId: 1, quantity: 1)],
    ));
    await store.write(const CartDocument(
      userKey: 'guest',
      lines: [CartLine(productId: 2, quantity: 1)],
    ));

    await store.delete('wp_1');

    expect((await store.read('wp_1')).lines, isEmpty);
    expect((await store.read('guest')).lines.single.productId, 2);
  });

  test('deleteAll clears every cart file', () async {
    await store.write(const CartDocument(
      userKey: 'wp_1',
      lines: [CartLine(productId: 1, quantity: 1)],
    ));
    await store.write(const CartDocument(
      userKey: 'guest',
      lines: [CartLine(productId: 2, quantity: 1)],
    ));

    await store.deleteAll();

    expect((await store.read('wp_1')).lines, isEmpty);
    expect((await store.read('guest')).lines, isEmpty);
  });

  test('stale temp files are swept on first access', () async {
    final dir = Directory('${root.path}/cart_cache')..createSync(recursive: true);
    File('${dir.path}/cart_wp_1.json.999.0.1.tmp').writeAsStringSync('partial');

    await store.read('wp_1');

    expect(
      dir.listSync().whereType<File>().where((f) => f.path.endsWith('.tmp')),
      isEmpty,
    );
  });
}
