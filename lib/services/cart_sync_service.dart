import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/local_first_sync_config.dart';
import '../features/cart/data/store_cart_json.dart';
import '../features/cart/data/store_cart_snapshot.dart';
import '../features/cart/domain/cart_item.dart';
import '../features/cart/domain/cart_sync_outcome.dart';
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

  bool _syncInFlight = false;

  /// After optimistic checkout, ignore remote cart items briefly so a slow
  /// Store API clear cannot resurrect the previous basket.
  DateTime? _suppressRemoteHydrateUntil;

  /// Prepares the on-disk cache. Deliberately starts **no timer**: the cart
  /// heartbeat is owned solely by [CartRemoteSyncBinding], which additionally
  /// gates on app lifecycle and sign-in state. Two independent 3-minute timers
  /// used to run here and there, so whichever fired second was swallowed by
  /// the `_syncInFlight` guard and reported as a failure to the UI.
  Future<void> init() async {
    await CartCacheService.instance.init();
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

  /// Friendly copy for a cart sync that could not reach the store.
  static const _friendlySyncError =
      "We're having trouble reaching our cart server. We'll keep trying.";

  /// Syncs the cart with the Store API.
  ///
  /// Returns a [CartSyncOutcome] rather than a nullable record so callers can
  /// tell "skipped" and "empty cart" apart from "failed" — all three used to
  /// collapse into `null` and surface as an error in the UI.
  Future<CartSyncOutcome> syncNow({bool force = false}) async {
    final key = await currentUserKey();

    if (_syncInFlight) {
      return CartSyncSkipped(
        CartSyncSkipReason.alreadyInFlight,
        await CartCacheService.instance.read(key),
      );
    }

    final prefs = await SharedPreferences.getInstance();
    final lastMs = prefs.getInt(_lastSyncKey) ?? 0;
    final elapsedMs = DateTime.now().millisecondsSinceEpoch - lastMs;
    if (!force &&
        elapsedMs < LocalFirstSyncConfig.cartSyncInterval.inMilliseconds) {
      return CartSyncSkipped(
        CartSyncSkipReason.throttled,
        await CartCacheService.instance.read(key),
      );
    }

    _syncInFlight = true;
    try {
      final existing = await CartCacheService.instance.read(key);

      if (!AuthService.instance.isSignedIn) {
        // Guest carts are local-only. Deliberately no write here: persisting a
        // transient `syncing` status used to strand the record in that state
        // until a signed-in sync happened to rewrite it.
        localSyncLog('cart sync skipped (guest/local only)');
        return CartSyncSkipped(CartSyncSkipReason.guest, existing);
      }

      if (existing != null) {
        await CartCacheService.instance.save(
          key,
          existing.copyWith(syncStatus: CartSyncStatus.syncing),
        );
      }

      await AuthService.instance.ensureValidSession();
      final remote = await StoreCartApiService.instance.fetchFullCart();
      if (!remote.success || remote.data == null) {
        localSyncLog('cart sync failed: Cart API unavailable');
        CartCacheRecord? failed;
        if (existing != null) {
          failed = existing.copyWith(
            syncStatus: CartSyncStatus.failed,
            lastSyncError: _friendlySyncError,
          );
          await CartCacheService.instance.save(key, failed);
        }
        return CartSyncFailed(
          userMessage: _friendlySyncError,
          debugDetail: 'fetchFullCart returned success=${remote.success}',
          record: failed,
        );
      }

      final data = remote.data!;
      var items = cartItemsFromStoreCartJson(data);
      if (_suppressRemoteHydrateUntil != null &&
          DateTime.now().isBefore(_suppressRemoteHydrateUntil!) &&
          items.isNotEmpty) {
        localSyncLog(
          'cart sync suppressed remote hydrate '
          '(checkout clear in flight, remoteItems=${items.length})',
        );
        await writeEmptySyncedCart(extendSuppress: false);
        await prefs.setInt(_lastSyncKey, DateTime.now().millisecondsSinceEpoch);
        final record = await CartCacheService.instance.read(key);
        return record == null
            ? const CartSyncSkipped(CartSyncSkipReason.alreadyInFlight)
            : CartSyncSucceeded(record);
      }
      if (items.isEmpty) {
        _suppressRemoteHydrateUntil = null;
      }
      await writeThroughRemote(items: items, rawJson: data);
      await prefs.setInt(_lastSyncKey, DateTime.now().millisecondsSinceEpoch);
      localSyncLog('cart sync ok items=${items.length}');
      final record = await CartCacheService.instance.read(key);
      // An empty cart is a legitimate, successful result.
      return CartSyncSucceeded(
        record ?? CartCacheRecord(items: items, snapshotJson: data),
      );
    } catch (e) {
      localSyncLog('cart sync exception: $e');
      CartCacheRecord? failed;
      final existing = await CartCacheService.instance.read(key);
      if (existing != null) {
        failed = existing.copyWith(
          syncStatus: CartSyncStatus.failed,
          lastSyncError: _friendlySyncError,
        );
        await CartCacheService.instance.save(key, failed);
      }
      return CartSyncFailed(
        userMessage: _friendlySyncError,
        debugDetail: e.toString(),
        record: failed,
      );
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

  /// Persist an empty cart as synced so background sync cannot resurrect
  /// stale Store API items after an optimistic checkout clear.
  Future<void> writeEmptySyncedCart({bool extendSuppress = true}) async {
    if (extendSuppress) {
      _suppressRemoteHydrateUntil =
          DateTime.now().add(const Duration(seconds: 60));
    }
    final key = await currentUserKey();
    await CartCacheService.instance.save(
      key,
      CartCacheRecord(
        items: const [],
        snapshotJson: const {
          'items': <dynamic>[],
          'items_count': 0,
          'items_weight': 0,
          'needs_payment': false,
          'needs_shipping': false,
          'totals': <String, dynamic>{},
        },
        syncStatus: CartSyncStatus.synced,
        updatedAt: DateTime.now(),
        lastSyncAt: DateTime.now(),
        lastSyncError: null,
      ),
    );
  }
}
