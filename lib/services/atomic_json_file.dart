import 'dart:async';
import 'dart:io';
import 'dart:math';

/// Crash-safe, concurrency-safe writes for the JSON caches in app documents.
///
/// Two properties the previous inline implementation lacked:
///  * a **unique** temp name per write, so two concurrent writers cannot share
///    (and clobber) the same `.tmp` file;
///  * `rename` straight over the destination instead of `delete`-then-`rename`,
///    so a concurrent reader never observes a missing file.
///
/// Writes to the same path are additionally serialized through an in-process
/// chain, making last-call-wins deterministic rather than scheduling-dependent.
class AtomicJsonFile {
  AtomicJsonFile._();

  static final Map<String, Future<void>> _chains = <String, Future<void>>{};
  static final Random _rand = Random();
  static int _counter = 0;

  /// Serialized atomic write. Completes after this write lands on disk.
  static Future<void> write(File file, String contents) {
    final previous = _chains[file.path] ?? Future<void>.value();
    final next = previous.then((_) => _writeOnce(file, contents));
    // Keep the chain alive even if this write throws, so later writes still run.
    _chains[file.path] = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  /// Windows `MoveFileExW` refuses to replace a destination that a reader
  /// currently holds open, unlike POSIX `rename(2)`. Readers hold the cart file
  /// for microseconds, so a short bounded retry converts that into a no-op
  /// rather than a lost write. Never falls back to writing in place — that
  /// would reintroduce the torn-read the temp file exists to prevent.
  static const int _renameAttempts = 12;

  static Future<void> _writeOnce(File file, String contents) async {
    final tmp = File(_tempPathFor(file));
    try {
      await tmp.writeAsString(contents, flush: true);
      await _renameWithRetry(tmp, file.path);
    } catch (_) {
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {
          // Best effort; a stale temp is swept on next init.
        }
      }
      rethrow;
    }
  }

  static Future<void> _renameWithRetry(File tmp, String destination) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await tmp.rename(destination);
        return;
      } on FileSystemException {
        if (attempt >= _renameAttempts - 1) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 2 * (attempt + 1)));
      }
    }
  }

  static String _tempPathFor(File file) {
    final n = _counter++;
    final salt = _rand.nextInt(1 << 20);
    return '${file.path}.${DateTime.now().microsecondsSinceEpoch}.$n.$salt.tmp';
  }

  /// Deletes `*.tmp` residue left behind by a crash or a failed rename.
  static Future<void> sweepTempFiles(Directory dir) async {
    try {
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.tmp')) {
          try {
            await entity.delete();
          } catch (_) {
            // Another process may own it; skip.
          }
        }
      }
    } catch (_) {
      // Sweeping is opportunistic — never block startup on it.
    }
  }

  /// Test seam: drops the per-path write chains.
  static void resetChainsForTest() => _chains.clear();
}
