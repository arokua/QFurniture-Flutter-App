import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/cart_cache_service.dart';
import '../../../services/cart_sync_service.dart';
import '../../../services/auth_service.dart';
import '../domain/cart_item.dart';
import 'cart_session_refresh.dart';
import 'store_cart_snapshot.dart';

/// Full cart state returned by the WooCommerce Store API.
class WooCartState {
  const WooCartState({
    required this.items,
    this.snapshot,
    this.rawJson,
    this.syncStatus = CartSyncStatus.idle,
    this.fromCache = false,
    this.lastSyncError,
  });

  final List<CartItem> items;
  final StoreCartApiSnapshot? snapshot;
  final Map<String, dynamic>? rawJson;
  final CartSyncStatus syncStatus;
  final bool fromCache;
  final String? lastSyncError;

  bool get isEmpty => items.isEmpty;

  static const empty = WooCartState(items: []);
}

/// Cache-first cart: read JSON immediately, sync WooCommerce in background.
class WooCartNotifier extends AsyncNotifier<WooCartState> {
  @override
  Future<WooCartState> build() async {
    if (!AuthService.instance.isSignedIn) return WooCartState.empty;

    final cached = await CartSyncService.instance.readCached();
    if (cached != null && cached.items.isNotEmpty) {
      unawaited(_refreshInBackground());
      return _fromCache(cached);
    }

    final synced = await CartSyncService.instance.syncNow(force: true);
    if (synced != null && synced.items.isNotEmpty) {
      return _fromCache(synced, fromCache: false);
    }

    try {
      return await _fetchNetwork();
    } catch (e) {
      if (cached != null) return _fromCache(cached);
      rethrow;
    }
  }

  WooCartState _fromCache(CartCacheRecord record, {bool fromCache = true}) {
    final snapshot = CartSyncService.instance.snapshotFromRecord(record);
    return WooCartState(
      items: record.items,
      snapshot: snapshot,
      rawJson: record.snapshotJson,
      syncStatus: record.syncStatus,
      fromCache: fromCache,
      lastSyncError: record.lastSyncError,
    );
  }

  Future<void> _refreshInBackground() async {
    final fresh = await CartSyncService.instance.syncNow(force: true);
    if (fresh == null) return;
    final next = _fromCache(fresh, fromCache: false);
    final current = state.valueOrNull;
    if (current == null || _changed(current, next)) {
      state = AsyncData(next);
    }
  }

  bool _changed(WooCartState a, WooCartState b) {
    if (a.items.length != b.items.length) return true;
    if (a.syncStatus != b.syncStatus) return true;
    for (var i = 0; i < a.items.length; i++) {
      if (a.items[i].productId != b.items[i].productId ||
          a.items[i].quantity != b.items[i].quantity) {
        return true;
      }
    }
    return false;
  }

  Future<WooCartState> _fetchNetwork() async {
    await ensureCartJwtFresh();

    var state = await _fetchWithCurrentSession();
    if (state != null) return state;

    await rebootstrapCartSession();
    state = await _fetchWithCurrentSession();
    if (state != null) return state;

    throw Exception('Cart API unavailable — pull to refresh');
  }

  Future<WooCartState?> _fetchWithCurrentSession() async {
    final synced = await CartSyncService.instance.syncNow(force: true);
    if (synced == null || synced.items.isEmpty) return null;
    return _fromCache(synced, fromCache: false);
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(build);
  }
}

final wooCartProvider =
    AsyncNotifierProvider<WooCartNotifier, WooCartState>(WooCartNotifier.new);
