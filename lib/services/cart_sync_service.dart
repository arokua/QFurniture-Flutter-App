import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/local_first_sync_config.dart';
import '../features/cart/data/store_cart_json.dart';
import '../features/cart/data/store_cart_snapshot.dart';
import '../features/cart/domain/cart_item.dart';
import 'auth_service.dart';
import 'cart_cache_service.dart';
import 'local_sync_logger.dart';
import 'order_history_sync_service.dart';
import '../config/store_cart_api_service.dart';

/// Local JSON first, WooCommerce Store API sync in background.
class CartSyncService {
  CartSyncService._();
  static final CartSyncService instance = CartSyncService._();

  static const _lastSyncKey = 'qf_cart_last_sync_ms';

  Timer? _periodic;
  bool _syncInFlight = false;

  Future<void> init() async {
    await CartCacheService.instance.init();
    _periodic?.cancel();
    _periodic = Timer.periodic(LocalFirstSyncConfig.cartSyncInterval, (_) {
      syncNow().ignore();
    });
  }

  void dispose() {
    _periodic?.cancel();
    _periodic = null;
  }

  Future<String> currentUserKey() async {
    if (!AuthService.instance.isSignedIn) return 'guest';
    final orderKey = await OrderHistorySyncService.instance.currentUserKey();
    if (orderKey != null) return orderKey;
    final email = AuthService.instance.currentSession?.email
        .trim()
        .toLowerCase();
    if (email != null && email.isNotEmpty) {
      return 'email_${email.hashCode}';
    }
    return 'guest';
  }

  /// Immediate disk write on any local cart mutation (no network).
  Future<void> writeThroughLocal({
    required List<CartItem> items,
    Map<String, dynamic>? snapshotJson,
    CartSyncStatus syncStatus = CartSyncStatus.pending,
    String? syncError,
  }) async {
    final key = await currentUserKey();
    final existing = await CartCacheService.instance.read(key);
    await CartCacheService.instance.save(
      key,
      CartCacheRecord(
        items: items,
        snapshotJson: snapshotJson ?? existing?.snapshotJson,
        syncStatus: syncStatus,
        updatedAt: DateTime.now(),
        lastSyncAt: existing?.lastSyncAt,
        lastSyncError: syncError,
      ),
    );
  }

  /// Persist a successful remote fetch to disk.
  Future<void> writeThroughRemote({
    required List<CartItem> items,
    required Map<String, dynamic> rawJson,
  }) async {
    final key = await currentUserKey();
    await CartCacheService.instance.save(
      key,
      CartCacheRecord(
        items: items,
        snapshotJson: rawJson,
        syncStatus: CartSyncStatus.synced,
        updatedAt: DateTime.now(),
        lastSyncAt: DateTime.now(),
        lastSyncError: null,
      ),
    );
  }

  Future<CartCacheRecord?> readCached() async {
    final key = await currentUserKey();
    return CartCacheService.instance.read(key);
  }

  /// Returns updated cache record when a network sync runs; null when skipped.
  Future<CartCacheRecord?> syncNow({bool force = false}) async {
    if (_syncInFlight) return null;

    final prefs = await SharedPreferences.getInstance();
    final lastMs = prefs.getInt(_lastSyncKey) ?? 0;
    final elapsedMs = DateTime.now().millisecondsSinceEpoch - lastMs;
    if (!force &&
        elapsedMs < LocalFirstSyncConfig.cartSyncInterval.inMilliseconds) {
      return null;
    }

    _syncInFlight = true;
    final key = await currentUserKey();
    try {
      final existing = await CartCacheService.instance.read(key);
      if (existing != null) {
        await CartCacheService.instance.save(
          key,
          existing.copyWith(syncStatus: CartSyncStatus.syncing),
        );
      }

      if (!AuthService.instance.isSignedIn) {
        localSyncLog('cart sync skipped (guest/local only)');
        return existing;
      }

      await AuthService.instance.ensureValidSession();
      final remote = await StoreCartApiService.instance.fetchFullCart();
      if (!remote.success || remote.data == null) {
        const err = 'Cart API unavailable';
        localSyncLog('cart sync failed: $err');
        if (existing != null) {
          final failed = existing.copyWith(
            syncStatus: CartSyncStatus.failed,
            lastSyncError: err,
          );
          await CartCacheService.instance.save(key, failed);
          return failed;
        }
        return null;
      }

      final data = remote.data!;
      final items = cartItemsFromStoreCartJson(data);
      await writeThroughRemote(items: items, rawJson: data);
      await prefs.setInt(_lastSyncKey, DateTime.now().millisecondsSinceEpoch);
      localSyncLog('cart sync ok items=${items.length}');
      return CartCacheService.instance.read(key);
    } catch (e) {
      localSyncLog('cart sync exception: $e');
      final existing = await CartCacheService.instance.read(key);
      if (existing != null) {
        final failed = existing.copyWith(
          syncStatus: CartSyncStatus.failed,
          lastSyncError: e.toString(),
        );
        await CartCacheService.instance.save(key, failed);
        return failed;
      }
      return null;
    } finally {
      _syncInFlight = false;
    }
  }

  StoreCartApiSnapshot? snapshotFromRecord(CartCacheRecord? record) {
    final json = record?.snapshotJson;
    if (json == null) return null;
    try {
      return StoreCartApiSnapshot.fromCartJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearOnSignOut() async {
    await CartCacheService.instance.clearAll();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastSyncKey);
  }

  Future<void> clearCurrentCart() async {
    final key = await currentUserKey();
    await CartCacheService.instance.clear(key);
  }
}
