import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:path_provider/path_provider.dart';

import '../../../services/atomic_json_file.dart';
import '../domain/cart_document.dart';

/// Reads and writes `cart_cache/cart_<userKey>.json`.
///
/// Intended to be driven by exactly one owner ([CartCoordinator]). The previous
/// design had `CartNotifier`, `CartSyncService` and the periodic timer all
/// writing the same file with no ordering, which is how local edits were lost.
class CartDocumentStore {
  CartDocumentStore({Future<Directory> Function()? directoryProvider})
      : _directoryProvider = directoryProvider ?? _defaultDirectory;

  static const String dirName = 'cart_cache';

  final Future<Directory> Function() _directoryProvider;
  bool _ready = false;

  /// Per-user write chains. Ordering is captured **synchronously** when
  /// [write] is called, before any `await`. Without this, resolving the file
  /// path asynchronously let concurrent writes enter the atomic layer in
  /// arbitrary order, so the last caller was not reliably the last writer.
  final Map<String, Future<void>> _writeChains = <String, Future<void>>{};

  static Future<Directory> _defaultDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/$dirName');
  }

  Future<Directory> _dir() async {
    final dir = await _directoryProvider();
    if (!_ready) {
      if (!await dir.exists()) await dir.create(recursive: true);
      await AtomicJsonFile.sweepTempFiles(dir);
      _ready = true;
    }
    return dir;
  }

  Future<File> fileFor(String userKey) async {
    final safe = userKey.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    final dir = await _dir();
    return File('${dir.path}/cart_$safe.json');
  }

  /// Never throws. A corrupt or missing file yields an empty document so the
  /// cart degrades to "empty" rather than crashing or wiping user data.
  Future<CartDocument> read(String userKey) async {
    try {
      final file = await fileFor(userKey);
      if (!await file.exists()) return CartDocument.empty(userKey);
      final text = await file.readAsString();
      if (text.trim().isEmpty) return CartDocument.empty(userKey);
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return CartDocument.empty(userKey);
      return CartDocument.fromJson(decoded, userKey);
    } catch (e) {
      if (kDebugMode) debugPrint('[CartDocStore] read error: $e');
      return CartDocument.empty(userKey);
    }
  }

  /// Deliberately not `async`: the chain must be extended before the first
  /// suspension point so call order is preserved.
  Future<void> write(CartDocument doc) {
    final previous = _writeChains[doc.userKey] ?? Future<void>.value();
    final next = previous.then((_) => _writeNow(doc));
    _writeChains[doc.userKey] = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  Future<void> _writeNow(CartDocument doc) async {
    final file = await fileFor(doc.userKey);
    await AtomicJsonFile.write(
      file,
      jsonEncode(doc.copyWith(updatedAt: DateTime.now()).toJson()),
    );
  }

  Future<void> delete(String userKey) async {
    try {
      final file = await fileFor(userKey);
      if (await file.exists()) await file.delete();
    } catch (e) {
      if (kDebugMode) debugPrint('[CartDocStore] delete error: $e');
    }
  }

  Future<void> deleteAll() async {
    try {
      final dir = await _dir();
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        if (entity is File) await entity.delete();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[CartDocStore] deleteAll error: $e');
    }
  }
}
