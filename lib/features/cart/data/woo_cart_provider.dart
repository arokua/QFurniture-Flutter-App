import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/cart_cache_service.dart';
import '../domain/cart_document.dart';
import '../domain/cart_item.dart';
import 'cart_providers.dart';
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

/// Projection of the coordinator's document.
///
/// Previously this held its own cache-first fetch logic and a `_changed`
/// comparison that looked only at ids and quantities — so a re-priced snapshot
/// was silently discarded, and an empty cart surfaced as a red error. It is now
/// a view: the coordinator owns fetching, reconciliation and persistence.
class WooCartNotifier extends AsyncNotifier<WooCartState> {
  StreamSubscription<CartDocument>? _sub;

  @override
  Future<WooCartState> build() async {
    final coordinator = cartCoordinator;

    _sub?.cancel();
    _sub = coordinator.stream.listen((doc) {
      state = AsyncData(_project(doc));
    });
    ref.onDispose(() => _sub?.cancel());

    await coordinator.ensureHydrated();
    return _project(coordinator.current);
  }

  WooCartState _project(CartDocument doc) {
    final snapshotJson = doc.confirmed?.snapshotJson;
    StoreCartApiSnapshot? snapshot;
    if (snapshotJson != null) {
      try {
        snapshot = StoreCartApiSnapshot.fromCartJson(snapshotJson);
      } catch (_) {
        snapshot = null;
      }
    }

    // Render confirmed prices, but with the user's pending intent overlaid so
    // the line the user just changed shows the quantity they chose.
    if (snapshot != null && doc.lines.isNotEmpty) {
      snapshot = _overlayIntent(snapshot, doc);
    }

    return WooCartState(
      items: doc.itemsView,
      snapshot: snapshot,
      rawJson: snapshotJson,
      syncStatus: doc.syncStatus,
      fromCache: doc.confirmed?.fetchedAt == null,
      lastSyncError: doc.lastSyncError,
    );
  }

  /// Applies local quantities on top of server-priced lines, and drops lines
  /// the user has removed locally but the server has not confirmed yet.
  StoreCartApiSnapshot _overlayIntent(
    StoreCartApiSnapshot snapshot,
    CartDocument doc,
  ) {
    final intent = <int, int>{
      for (final l in doc.lines) l.productId: l.quantity,
    };

    final lines = <StoreCartLineItem>[];
    for (final line in snapshot.lines) {
      final wanted = intent.remove(line.productId);
      if (wanted == null) {
        // Removed locally; hide it immediately rather than waiting on the queue.
        if (doc.hasPendingFor(line.productId)) continue;
        lines.add(line);
        continue;
      }
      if (wanted == line.quantity) {
        lines.add(line);
        continue;
      }
      final unit = line.priceMinor;
      lines.add(StoreCartLineItem(
        productId: line.productId,
        quantity: wanted,
        name: line.name,
        sku: line.sku,
        cartItemKey: line.cartItemKey,
        priceMinor: unit,
        lineTotalMinor: unit != null ? unit * wanted : line.lineTotalMinor,
        currencySymbol: line.currencySymbol,
        minorUnit: line.minorUnit,
        imageUrl: line.imageUrl,
      ));
    }

    if (lines.length == snapshot.lines.length && intent.isEmpty) {
      return snapshot;
    }
    return StoreCartApiSnapshot(
      totalsView: snapshot.totalsView,
      lines: lines,
      errors: snapshot.errors,
    );
  }

  /// Pull-to-refresh.
  Future<void> refresh() async {
    await cartCoordinator.reconcile(force: true);
  }
}

final wooCartProvider =
    AsyncNotifierProvider<WooCartNotifier, WooCartState>(WooCartNotifier.new);
