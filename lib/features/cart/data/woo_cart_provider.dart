import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/cart_cache_service.dart';
import '../../../services/cart_sync_service.dart';
import '../../../services/auth_service.dart';
import '../domain/cart_item.dart';
import '../domain/cart_sync_outcome.dart';
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

    final outcome = await CartSyncService.instance.syncNow(force: true);
    if (outcome is CartSyncSucceeded) {
      // Includes the empty-cart case: an empty cart is a real answer, and the
      // caller must render the empty state rather than an error.
      return _fromCache(outcome.record, fromCache: false);
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
    final outcome = await CartSyncService.instance.syncNow(force: true);
    if (outcome is! CartSyncSucceeded) return;
    final next = _fromCache(outcome.record, fromCache: false);
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
    // Quantities can be identical while prices or totals have moved (role
    // re-pricing, a store-side price change). Comparing only ids/quantities
    // silently dropped those updates, so compare the rendered totals too.
    return _totalsSignature(a) != _totalsSignature(b);
  }

  String _totalsSignature(WooCartState s) {
    final tv = s.snapshot?.totalsView;
    if (tv == null) return '-';
    return '${tv.totalPriceMinor}/${tv.totalItemsMinor}/'
        '${tv.totalTaxMinor}/${tv.totalShippingMinor}';
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
    final outcome = await CartSyncService.instance.syncNow(force: true);
    // Only a genuine failure justifies falling through to the retry ladder.
    // Success (empty or not) and skips must not be treated as unavailability.
    if (outcome is CartSyncSucceeded) {
      return _fromCache(outcome.record, fromCache: false);
    }
    final record = outcome.record;
    if (outcome is CartSyncSkipped && record != null) {
      return _fromCache(record);
    }
    return null;
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(build);
  }
}

final wooCartProvider =
    AsyncNotifierProvider<WooCartNotifier, WooCartState>(WooCartNotifier.new);
