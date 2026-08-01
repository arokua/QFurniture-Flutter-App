import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:path_provider/path_provider.dart';

import '../../../services/atomic_json_file.dart';
import '../domain/checkout_attempt.dart';

/// Reads and writes `checkout_state/checkout_attempt.json`.
///
/// Uses [AtomicJsonFile] for the same reason the cart does: the record is
/// written immediately before a network call, so a process death mid-write
/// must never leave a half-parsed file. A torn record here would be worse
/// than a torn cart — it decides whether an order is resubmitted or not.
///
/// Only one attempt is kept. Checkout is strictly serialized (the cart's
/// checkout hold guarantees it), so there is never a second live attempt, and
/// keeping a history would only add a pruning problem.
class CheckoutAttemptStore {
  CheckoutAttemptStore({Future<Directory> Function()? directoryProvider})
      : _directoryProvider = directoryProvider ?? _defaultDirectory;

  static const String dirName = 'checkout_state';
  static const String fileName = 'checkout_attempt.json';

  final Future<Directory> Function() _directoryProvider;
  bool _ready = false;

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

  Future<File> file() async => File('${(await _dir()).path}/$fileName');

  /// Never throws. A missing or corrupt record reads as "no attempt", which is
  /// the safe interpretation: reconciliation does nothing and the cart is left
  /// exactly as the user last saw it.
  Future<CheckoutAttempt?> read() async {
    try {
      final f = await file();
      if (!await f.exists()) return null;
      final text = await f.readAsString();
      if (text.trim().isEmpty) return null;
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return null;
      return CheckoutAttempt.fromJson(decoded);
    } catch (e) {
      if (kDebugMode) debugPrint('[CheckoutAttemptStore] read error: $e');
      return null;
    }
  }

  Future<void> write(CheckoutAttempt attempt) async {
    final f = await file();
    await AtomicJsonFile.write(
      f,
      jsonEncode(attempt.copyWith(updatedAt: DateTime.now()).toJson()),
    );
  }

  Future<void> clear() async {
    try {
      final f = await file();
      if (await f.exists()) await f.delete();
    } catch (e) {
      if (kDebugMode) debugPrint('[CheckoutAttemptStore] clear error: $e');
    }
  }
}
