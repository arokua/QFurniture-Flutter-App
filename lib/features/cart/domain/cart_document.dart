import '../../../services/cart_cache_service.dart' show CartSyncStatus;
import 'cart_item.dart';
import 'cart_mutation.dart';

/// One line of **user intent**.
///
/// [lastLocalSeq] stamps the sequence at which the user last touched this
/// product. A server response issued before that sequence is stale for this
/// line and must not overwrite it.
class CartLine {
  const CartLine({
    required this.productId,
    required this.quantity,
    this.lastLocalSeq = 0,
  });

  final int productId;
  final int quantity;
  final int lastLocalSeq;

  CartLine copyWith({int? quantity, int? lastLocalSeq}) => CartLine(
        productId: productId,
        quantity: quantity ?? this.quantity,
        lastLocalSeq: lastLocalSeq ?? this.lastLocalSeq,
      );

  CartItem toCartItem() => CartItem(productId: productId, quantity: quantity);

  Map<String, dynamic> toJson() => {
        'productId': productId,
        'quantity': quantity,
        'lastLocalSeq': lastLocalSeq,
      };

  static CartLine? fromJson(Map<String, dynamic> j) {
    final pid = _asInt(j['productId']);
    final qty = _asInt(j['quantity']);
    if (pid <= 0 || qty <= 0) return null;
    return CartLine(
      productId: pid,
      quantity: qty,
      lastLocalSeq: _asInt(j['lastLocalSeq']),
    );
  }

  @override
  String toString() => 'CartLine(p$productId x$quantity @$lastLocalSeq)';
}

/// The last thing the **server** told us, kept separate from intent.
///
/// Merging these two into a single list is what allowed a slow `GET /cart` to
/// overwrite a newer local change.
class ConfirmedCart {
  const ConfirmedCart({
    this.lines = const [],
    this.snapshotJson,
    this.cartItemKeyByProductId = const {},
    this.fetchedAt,
  });

  final List<CartItem> lines;
  final Map<String, dynamic>? snapshotJson;

  /// Store API line keys, needed to address `update-item` / `remove-item`
  /// without an extra `GET /cart/items` round trip.
  final Map<int, String> cartItemKeyByProductId;

  final DateTime? fetchedAt;

  Map<String, dynamic> toJson() => {
        'lines': lines
            .map((e) => {'productId': e.productId, 'quantity': e.quantity})
            .toList(),
        if (snapshotJson != null) 'snapshot': snapshotJson,
        'itemKeys': cartItemKeyByProductId
            .map((k, v) => MapEntry(k.toString(), v)),
        if (fetchedAt != null) 'fetchedAt': fetchedAt!.toUtc().toIso8601String(),
      };

  static ConfirmedCart fromJson(Map<String, dynamic> j) {
    final lines = <CartItem>[];
    final rawLines = j['lines'];
    if (rawLines is List) {
      for (final e in rawLines) {
        if (e is! Map) continue;
        final pid = _asInt(e['productId']);
        final qty = _asInt(e['quantity']);
        if (pid > 0 && qty > 0) {
          lines.add(CartItem(productId: pid, quantity: qty));
        }
      }
    }

    final keys = <int, String>{};
    final rawKeys = j['itemKeys'];
    if (rawKeys is Map) {
      rawKeys.forEach((k, v) {
        final pid = int.tryParse(k.toString());
        final key = v?.toString();
        if (pid != null && pid > 0 && key != null && key.isNotEmpty) {
          keys[pid] = key;
        }
      });
    }

    final snap = j['snapshot'];
    return ConfirmedCart(
      lines: lines,
      snapshotJson: snap is Map<String, dynamic> ? snap : null,
      cartItemKeyByProductId: keys,
      fetchedAt: DateTime.tryParse((j['fetchedAt'] ?? '').toString()),
    );
  }
}

/// The complete on-disk cart state owned by a single writer.
class CartDocument {
  const CartDocument({
    required this.userKey,
    this.revision = 0,
    this.localSequence = 0,
    this.lines = const [],
    this.confirmed,
    this.pending = const [],
    this.syncStatus = CartSyncStatus.idle,
    this.lastSyncError,
    this.checkoutHoldId,
    this.checkoutHoldAt,
    this.updatedAt,
  });

  static const int schemaVersion = 2;

  final String userKey;

  /// Bumped on every accepted local intent change.
  final int revision;

  /// Monotonic, never reset. Stamps lines and mutations for staleness checks.
  final int localSequence;

  final List<CartLine> lines;
  final ConfirmedCart? confirmed;
  final List<CartMutation> pending;

  /// Never persisted as [CartSyncStatus.syncing] — that is transient state.
  final CartSyncStatus syncStatus;

  final String? lastSyncError;

  /// Active checkout attempt id. While set, cart mutations are refused so a
  /// basket cannot change underneath an order being submitted.
  final String? checkoutHoldId;
  final DateTime? checkoutHoldAt;

  final DateTime? updatedAt;

  CartDocument.empty(this.userKey)
      : revision = 0,
        localSequence = 0,
        lines = const [],
        confirmed = null,
        pending = const [],
        syncStatus = CartSyncStatus.idle,
        lastSyncError = null,
        checkoutHoldId = null,
        checkoutHoldAt = null,
        updatedAt = null;

  bool get isEmpty => lines.isEmpty;

  bool get hasPendingWork =>
      pending.any((m) => m.state != CartMutationState.failedPermanent);

  int get totalQuantity => lines.fold(0, (sum, l) => sum + l.quantity);

  int quantityOf(int productId) {
    for (final l in lines) {
      if (l.productId == productId) return l.quantity;
    }
    return 0;
  }

  bool hasPendingFor(int productId) => pending.any(
        (m) =>
            m.state != CartMutationState.failedPermanent &&
            (m.op == CartMutationOp.clearAll || m.productId == productId),
      );

  List<CartItem> get itemsView =>
      lines.map((l) => l.toCartItem()).toList(growable: false);

  /// True when the hold is set and has not outlived [ttl].
  bool holdIsActive(Duration ttl, DateTime now) {
    if (checkoutHoldId == null) return false;
    final at = checkoutHoldAt;
    if (at == null) return true;
    return now.difference(at) < ttl;
  }

  CartDocument copyWith({
    String? userKey,
    int? revision,
    int? localSequence,
    List<CartLine>? lines,
    ConfirmedCart? confirmed,
    bool clearConfirmed = false,
    List<CartMutation>? pending,
    CartSyncStatus? syncStatus,
    String? lastSyncError,
    bool clearLastSyncError = false,
    String? checkoutHoldId,
    DateTime? checkoutHoldAt,
    bool clearCheckoutHold = false,
    DateTime? updatedAt,
  }) {
    return CartDocument(
      userKey: userKey ?? this.userKey,
      revision: revision ?? this.revision,
      localSequence: localSequence ?? this.localSequence,
      lines: lines ?? this.lines,
      confirmed: clearConfirmed ? null : (confirmed ?? this.confirmed),
      pending: pending ?? this.pending,
      syncStatus: syncStatus ?? this.syncStatus,
      lastSyncError:
          clearLastSyncError ? null : (lastSyncError ?? this.lastSyncError),
      checkoutHoldId:
          clearCheckoutHold ? null : (checkoutHoldId ?? this.checkoutHoldId),
      checkoutHoldAt:
          clearCheckoutHold ? null : (checkoutHoldAt ?? this.checkoutHoldAt),
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    // `syncing` is deliberately never written: persisting it used to strand
    // records in that state when a sync returned early.
    final persistedStatus = syncStatus == CartSyncStatus.syncing
        ? CartSyncStatus.pending
        : syncStatus;
    return {
      'schemaVersion': schemaVersion,
      'userKey': userKey,
      'revision': revision,
      'localSequence': localSequence,
      'lines': lines.map((l) => l.toJson()).toList(),
      if (confirmed != null) 'confirmed': confirmed!.toJson(),
      'pending': pending.map((m) => m.toJson()).toList(),
      'syncStatus': persistedStatus.name,
      if (lastSyncError != null) 'lastSyncError': lastSyncError,
      if (checkoutHoldId != null) 'checkoutHoldId': checkoutHoldId,
      if (checkoutHoldAt != null)
        'checkoutHoldAt': checkoutHoldAt!.toUtc().toIso8601String(),
      'updatedAt': (updatedAt ?? DateTime.now()).toUtc().toIso8601String(),
    };
  }

  /// Reads either schema. Returns an empty document for anything unparseable
  /// rather than throwing — a corrupt cache must never crash the cart.
  static CartDocument fromJson(Map<String, dynamic> j, String fallbackKey) {
    final version = _asInt(j['schemaVersion'] ?? j['version']);
    if (version < schemaVersion) return _fromV1(j, fallbackKey);

    final lines = <CartLine>[];
    final rawLines = j['lines'];
    if (rawLines is List) {
      for (final e in rawLines) {
        if (e is! Map<String, dynamic>) continue;
        final line = CartLine.fromJson(e);
        if (line != null) lines.add(line);
      }
    }

    final pending = <CartMutation>[];
    final rawPending = j['pending'];
    if (rawPending is List) {
      for (final e in rawPending) {
        if (e is! Map<String, dynamic>) continue;
        final m = CartMutation.fromJson(e);
        if (m != null) pending.add(m);
      }
    }
    pending.sort((a, b) => a.localSequence.compareTo(b.localSequence));

    final rawConfirmed = j['confirmed'];
    return CartDocument(
      userKey: j['userKey']?.toString() ?? fallbackKey,
      revision: _asInt(j['revision']),
      localSequence: _asInt(j['localSequence']),
      lines: lines,
      confirmed: rawConfirmed is Map<String, dynamic>
          ? ConfirmedCart.fromJson(rawConfirmed)
          : null,
      pending: pending,
      syncStatus: _statusFrom(j['syncStatus']),
      lastSyncError: j['lastSyncError']?.toString(),
      checkoutHoldId: j['checkoutHoldId']?.toString(),
      checkoutHoldAt:
          DateTime.tryParse((j['checkoutHoldAt'] ?? '').toString()),
      updatedAt: DateTime.tryParse((j['updatedAt'] ?? '').toString()),
    );
  }

  /// Migrates the legacy `CartCacheRecord` shape, preserving items and the
  /// last Store API snapshot so an upgrading user keeps their basket.
  static CartDocument _fromV1(Map<String, dynamic> j, String fallbackKey) {
    final lines = <CartLine>[];
    final rawItems = j['items'];
    if (rawItems is List) {
      for (final e in rawItems) {
        if (e is! Map) continue;
        final pid = _asInt(e['productId']);
        final qty = _asInt(e['quantity']);
        if (pid > 0 && qty > 0) {
          lines.add(CartLine(productId: pid, quantity: qty));
        }
      }
    }

    final snap = j['snapshot'];
    return CartDocument(
      userKey: fallbackKey,
      revision: 0,
      localSequence: 0,
      lines: lines,
      confirmed: ConfirmedCart(
        lines: lines.map((l) => l.toCartItem()).toList(),
        snapshotJson: snap is Map<String, dynamic> ? snap : null,
        fetchedAt: DateTime.tryParse((j['lastSyncAt'] ?? '').toString()),
      ),
      // Pending mutations did not exist in v1; nothing to replay.
      pending: const [],
      syncStatus: _statusFrom(j['syncStatus']),
      lastSyncError: j['lastSyncError']?.toString(),
      updatedAt: DateTime.tryParse((j['updatedAt'] ?? '').toString()),
    );
  }

  static CartSyncStatus _statusFrom(Object? raw) {
    final name = (raw ?? 'idle').toString();
    final status = CartSyncStatus.values.firstWhere(
      (s) => s.name == name,
      orElse: () => CartSyncStatus.idle,
    );
    // Defensive: an old file may still carry a stranded `syncing`.
    return status == CartSyncStatus.syncing ? CartSyncStatus.pending : status;
  }

  @override
  String toString() => 'CartDocument($userKey rev=$revision seq=$localSequence '
      'lines=${lines.length} pending=${pending.length} ${syncStatus.name})';
}

int _asInt(Object? v) {
  if (v is int) return v;
  return int.tryParse(v?.toString() ?? '') ?? 0;
}
