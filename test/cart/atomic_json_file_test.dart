import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:Qtoys/services/atomic_json_file.dart';

void main() {
  late Directory dir;

  setUp(() {
    AtomicJsonFile.resetChainsForTest();
    dir = Directory.systemTemp.createTempSync('atomic_json_test');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File target() => File('${dir.path}/cart_user.json');

  test('writes and reads back a single payload', () async {
    await AtomicJsonFile.write(target(), jsonEncode({'a': 1}));
    expect(jsonDecode(target().readAsStringSync()), {'a': 1});
  });

  test('50 concurrent writes leave exactly one parseable file', () async {
    final file = target();
    // Fire without awaiting so every write races through the same chain.
    final futures = <Future<void>>[
      for (var i = 0; i < 50; i++)
        AtomicJsonFile.write(file, jsonEncode({'seq': i})),
    ];
    await Future.wait(futures);

    expect(file.existsSync(), isTrue);
    final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    // Serialized chain ⇒ the last enqueued write is the one that survives.
    expect(decoded['seq'], 49);

    final residue = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.tmp'))
        .toList();
    expect(residue, isEmpty, reason: 'no temp files may be left behind');
  });

  test('concurrent writers never share a temp path', () async {
    final file = target();
    // Two chains would collide on a fixed `${path}.tmp`; unique names must not.
    final big = jsonEncode({'pad': List<int>.filled(20000, 7)});
    final small = jsonEncode({'pad': <int>[]});
    await Future.wait([
      AtomicJsonFile.write(file, big),
      AtomicJsonFile.write(file, small),
    ]);
    // Whatever won, the file must be complete JSON — never a truncated blend.
    expect(() => jsonDecode(file.readAsStringSync()), returnsNormally);
  });

  test('a concurrent reader never observes a missing file', () async {
    final file = target();
    await AtomicJsonFile.write(file, jsonEncode({'seq': -1}));

    var sawMissing = false;
    var sawUnparseable = false;
    var sawSharingViolation = false;
    var reading = true;

    final reader = () async {
      while (reading) {
        if (!file.existsSync()) {
          sawMissing = true;
        } else {
          try {
            final text = file.readAsStringSync();
            if (text.isNotEmpty) jsonDecode(text);
          } on FormatException {
            sawUnparseable = true;
          } on FileSystemException {
            // Windows only: opening the file the instant MoveFileEx swaps it
            // yields a sharing violation. The file still exists and the next
            // read succeeds, so this is not the data-loss regression.
            sawSharingViolation = true;
          }
        }
        await Future<void>.delayed(Duration.zero);
      }
    }();

    for (var i = 0; i < 40; i++) {
      await AtomicJsonFile.write(file, jsonEncode({'seq': i}));
    }
    reading = false;
    await reader;

    // This is the exact regression: the old delete-then-rename opened a window
    // where the cart screen read no file and rendered "Your cart is empty".
    expect(sawMissing, isFalse, reason: 'file must never disappear mid-write');
    expect(sawUnparseable, isFalse, reason: 'readers must never see a torn write');
    expect(file.existsSync(), isTrue);
    expect(jsonDecode(file.readAsStringSync()), {'seq': 39});
    if (sawSharingViolation && !Platform.isWindows) {
      fail('sharing violations are a Windows-only artifact');
    }
  });

  test('sweepTempFiles removes crash residue but keeps real files', () async {
    final file = target();
    await AtomicJsonFile.write(file, jsonEncode({'keep': true}));
    File('${dir.path}/cart_user.json.123.0.99.tmp').writeAsStringSync('partial');
    File('${dir.path}/orders_x.json.9.1.4.tmp').writeAsStringSync('partial');

    await AtomicJsonFile.sweepTempFiles(dir);

    expect(file.existsSync(), isTrue);
    expect(jsonDecode(file.readAsStringSync()), {'keep': true});
    expect(
      dir.listSync().whereType<File>().where((f) => f.path.endsWith('.tmp')),
      isEmpty,
    );
  });

  test('a failed write does not break later writes on the same path', () async {
    final file = target();
    // Writing to a path whose parent does not exist fails; the chain must survive.
    final bad = File('${dir.path}/missing_dir/x.json');
    await expectLater(
      AtomicJsonFile.write(bad, '{}'),
      throwsA(isA<FileSystemException>()),
    );
    await AtomicJsonFile.write(file, jsonEncode({'ok': 1}));
    expect(jsonDecode(file.readAsStringSync()), {'ok': 1});
  });
}
