import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:path_provider/path_provider.dart';

import '../features/orders/domain/woo_order_summary.dart';
import 'app_storage_permission.dart';

/// Persists order history per signed-in user as JSON in app documents.
class OrderHistoryCacheService {
  OrderHistoryCacheService._();
  static final OrderHistoryCacheService instance = OrderHistoryCacheService._();

  static const _cacheVersion = 1;
  static const _dirName = 'order_history_cache';

  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    await AppStoragePermission.ensureGranted();
    final dir = await _cacheDir();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _ready = true;
  }

  Future<Directory> _cacheDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/$_dirName');
  }

  Future<File> _fileForUser(String userKey) async {
    final safe = userKey.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    final dir = await _cacheDir();
    return File('${dir.path}/orders_$safe.json');
  }

  Future<List<WooOrderSummary>> readOrders(String userKey) async {
    await init();
    try {
      final file = await _fileForUser(userKey);
      if (!await file.exists()) return const [];
      final text = await file.readAsString();
      if (text.trim().isEmpty) return const [];
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return const [];
      final ordersRaw = decoded['orders'];
      if (ordersRaw is! List) return const [];
      return ordersRaw
          .whereType<Map<String, dynamic>>()
          .map(WooOrderSummary.fromJson)
          .where((o) => o.id > 0)
          .toList();
    } catch (e) {
      if (kDebugMode) debugPrint('[OrderHistoryCache] read error: $e');
      return const [];
    }
  }

  Future<void> saveOrders(String userKey, List<WooOrderSummary> orders) async {
    await init();
    final sorted = List<WooOrderSummary>.from(orders)
      ..sort((a, b) => b.dateCreated.compareTo(a.dateCreated));
    final payload = jsonEncode({
      'version': _cacheVersion,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'orders': sorted.map((o) => o.toJson()).toList(),
    });
    await _atomicWrite(await _fileForUser(userKey), payload);
  }

  Future<void> upsertOrder(String userKey, WooOrderSummary order) async {
    if (order.id <= 0) return;
    final existing = await readOrders(userKey);
    final merged = <WooOrderSummary>[order];
    final seen = <int>{order.id};
    for (final o in existing) {
      if (seen.add(o.id)) merged.add(o);
    }
    await saveOrders(userKey, merged);
  }

  Future<void> clearForUser(String userKey) async {
    await init();
    try {
      final file = await _fileForUser(userKey);
      if (await file.exists()) await file.delete();
    } catch (e) {
      if (kDebugMode) debugPrint('[OrderHistoryCache] clear user error: $e');
    }
  }

  Future<void> clearAll() async {
    await init();
    try {
      final dir = await _cacheDir();
      if (await dir.exists()) {
        await for (final entity in dir.list()) {
          if (entity is File) await entity.delete();
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[OrderHistoryCache] clearAll error: $e');
    }
  }

  Future<void> _atomicWrite(File file, String contents) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
  }
}
