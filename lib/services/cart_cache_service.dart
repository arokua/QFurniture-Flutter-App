import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:path_provider/path_provider.dart';

import '../features/cart/domain/cart_item.dart';
import 'app_storage_permission.dart';
import 'local_sync_logger.dart';

enum CartSyncStatus { idle, pending, syncing, synced, failed }

/// On-disk cart snapshot (items + optional Store API JSON + sync metadata).
class CartCacheRecord {
  const CartCacheRecord({
    required this.items,
    this.snapshotJson,
    this.syncStatus = CartSyncStatus.idle,
    this.updatedAt,
    this.lastSyncAt,
    this.lastSyncError,
  });

  final List<CartItem> items;
  final Map<String, dynamic>? snapshotJson;
  final CartSyncStatus syncStatus;
  final DateTime? updatedAt;
  final DateTime? lastSyncAt;
  final String? lastSyncError;

  bool get isEmpty => items.isEmpty;

  CartCacheRecord copyWith({
    List<CartItem>? items,
    Map<String, dynamic>? snapshotJson,
    bool clearSnapshotJson = false,
    CartSyncStatus? syncStatus,
    DateTime? updatedAt,
    DateTime? lastSyncAt,
    String? lastSyncError,
    bool clearLastSyncError = false,
  }) {
    return CartCacheRecord(
      items: items ?? this.items,
      snapshotJson:
          clearSnapshotJson ? null : (snapshotJson ?? this.snapshotJson),
      syncStatus: syncStatus ?? this.syncStatus,
      updatedAt: updatedAt ?? this.updatedAt,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      lastSyncError:
          clearLastSyncError ? null : (lastSyncError ?? this.lastSyncError),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'updatedAt': (updatedAt ?? DateTime.now()).toUtc().toIso8601String(),
        if (lastSyncAt != null)
          'lastSyncAt': lastSyncAt!.toUtc().toIso8601String(),
        'syncStatus': syncStatus.name,
        if (lastSyncError != null) 'lastSyncError': lastSyncError,
        'items': items
            .map((e) => {'productId': e.productId, 'quantity': e.quantity})
            .toList(),
        if (snapshotJson != null) 'snapshot': snapshotJson,
      };

  factory CartCacheRecord.fromJson(Map<String, dynamic> j) {
    final itemsRaw = j['items'];
    final items = <CartItem>[];
    if (itemsRaw is List) {
      for (final e in itemsRaw) {
        if (e is! Map) continue;
        final pid = e['productId'];
        final qty = e['quantity'];
        final productId =
            pid is int ? pid : int.tryParse(pid?.toString() ?? '') ?? 0;
        final quantity =
            qty is int ? qty : int.tryParse(qty?.toString() ?? '') ?? 0;
        if (productId > 0 && quantity > 0) {
          items.add(CartItem(productId: productId, quantity: quantity));
        }
      }
    }

    final statusRaw = (j['syncStatus'] ?? 'idle').toString();
    final syncStatus = CartSyncStatus.values.firstWhere(
      (s) => s.name == statusRaw,
      orElse: () => CartSyncStatus.idle,
    );

    Map<String, dynamic>? snapshot;
    final snapRaw = j['snapshot'];
    if (snapRaw is Map<String, dynamic>) snapshot = snapRaw;

    return CartCacheRecord(
      items: items,
      snapshotJson: snapshot,
      syncStatus: syncStatus,
      updatedAt: DateTime.tryParse((j['updatedAt'] ?? '').toString()),
      lastSyncAt: DateTime.tryParse((j['lastSyncAt'] ?? '').toString()),
      lastSyncError: j['lastSyncError']?.toString(),
    );
  }
}

/// Persists cart state per guest or signed-in user as JSON in app documents.
class CartCacheService {
  CartCacheService._();
  static final CartCacheService instance = CartCacheService._();

  static const _dirName = 'cart_cache';
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

  Future<File> _fileForKey(String userKey) async {
    final safe = userKey.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    final dir = await _cacheDir();
    return File('${dir.path}/cart_$safe.json');
  }

  Future<CartCacheRecord?> read(String userKey) async {
    await init();
    try {
      final file = await _fileForKey(userKey);
      if (!await file.exists()) return null;
      final text = await file.readAsString();
      if (text.trim().isEmpty) return null;
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return null;
      return CartCacheRecord.fromJson(decoded);
    } catch (e) {
      if (kDebugMode) debugPrint('[CartCache] read error: $e');
      return null;
    }
  }

  Future<void> save(String userKey, CartCacheRecord record) async {
    await init();
    final payload = jsonEncode(record.toJson());
    await _atomicWrite(await _fileForKey(userKey), payload);
    localSyncLog('cart saved key=$userKey items=${record.items.length} '
        'status=${record.syncStatus.name}');
  }

  Future<void> clear(String userKey) async {
    await init();
    try {
      final file = await _fileForKey(userKey);
      if (await file.exists()) await file.delete();
      localSyncLog('cart cleared key=$userKey');
    } catch (e) {
      if (kDebugMode) debugPrint('[CartCache] clear error: $e');
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
      if (kDebugMode) debugPrint('[CartCache] clearAll error: $e');
    }
  }

  Future<void> _atomicWrite(File file, String contents) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
  }
}
