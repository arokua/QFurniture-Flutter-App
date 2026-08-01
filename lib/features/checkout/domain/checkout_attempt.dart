import 'dart:math';

/// Lifecycle of a single order submission.
///
/// The whole point of persisting this is the gap between "we sent the POST"
/// and "we know what happened to it". Before this existed the cart was emptied
/// *before* the request went out, so a failed or interrupted POST left the
/// basket unrecoverable and the user with no order.
///
/// The ordering of the writes matters more than the states themselves:
/// [dispatched] is written **to disk before the request leaves**, so a process
/// death is always attributable. A record still sitting in [preparing] proves
/// the POST never went out; anything in [dispatched] may or may not have
/// landed and must be resolved by asking the server.
enum CheckoutAttemptState {
  /// Record written, cart frozen, nothing sent yet. Safe to abandon.
  preparing,

  /// The POST is in flight, or the process died while it was. Ambiguous —
  /// only a server lookup can settle it.
  dispatched,

  /// A real WooCommerce order id came back. The only state that may clear the
  /// cart.
  confirmed,

  /// The server definitively rejected the order. The cart is kept.
  failed,

  /// Dispatched, but the outcome could not be determined (timeout, socket
  /// error, app killed). The cart is kept and reconciliation retries the
  /// lookup. Never resubmitted automatically.
  unknown,
}

/// One line of the basket as it was at submission time.
///
/// Snapshotted onto the record so a failed attempt can be explained (and, if
/// it ever becomes necessary, restored) without depending on the live cart.
class CheckoutAttemptLine {
  const CheckoutAttemptLine({
    required this.productId,
    required this.quantity,
    this.name = '',
  });

  final int productId;
  final int quantity;
  final String name;

  Map<String, dynamic> toJson() => {
        'productId': productId,
        'quantity': quantity,
        if (name.isNotEmpty) 'name': name,
      };

  static CheckoutAttemptLine? fromJson(Map<String, dynamic> j) {
    final pid = _asInt(j['productId']);
    final qty = _asInt(j['quantity']);
    if (pid <= 0 || qty <= 0) return null;
    return CheckoutAttemptLine(
      productId: pid,
      quantity: qty,
      name: (j['name'] ?? '').toString(),
    );
  }

  @override
  String toString() => 'CheckoutAttemptLine(p$productId x$quantity)';
}

/// A crash-safe record of one checkout, persisted before the order is sent.
class CheckoutAttempt {
  const CheckoutAttempt({
    required this.attemptId,
    required this.clientOrderKey,
    required this.userKey,
    required this.state,
    required this.lines,
    required this.createdAt,
    this.updatedAt,
    this.dispatchedAt,
    this.resolvedAt,
    this.orderId,
    this.orderNumber,
    this.error,
    this.localRef,
    this.totalDisplay,
    this.lookupAttempts = 0,
    this.drainSettled = true,
  });

  static const int schemaVersion = 1;

  /// Stable for the life of the attempt, including across retries and process
  /// restarts. The previous implementation derived a key from a 2-second time
  /// bucket, so a retry minted a *different* key and lost all duplicate
  /// protection.
  final String attemptId;

  /// Sent to WooCommerce as the `qtoys_client_order_key` order meta, and the
  /// value reconciliation matches on. Equal to [attemptId]; kept as its own
  /// field so the wire contract can diverge later without a migration.
  final String clientOrderKey;

  /// Which signed-in user this attempt belongs to. An attempt is never
  /// reconciled against a different account.
  final String userKey;

  final CheckoutAttemptState state;
  final List<CheckoutAttemptLine> lines;

  final DateTime createdAt;
  final DateTime? updatedAt;
  final DateTime? dispatchedAt;
  final DateTime? resolvedAt;

  /// Set only once WooCommerce has returned a real order.
  final int? orderId;
  final String? orderNumber;

  final String? error;

  /// Ties the attempt to its optimistic row in local order history.
  final String? localRef;

  final String? totalDisplay;

  /// How many times reconciliation has looked for this order without finding
  /// it. Bounds the search so an order that truly never landed is eventually
  /// declared failed instead of being probed forever.
  final int lookupAttempts;

  /// Whether queued cart mutations had settled when this order was submitted.
  ///
  /// Diagnostic only — it deliberately does not block checkout. The order is
  /// POSTed with explicit `line_items` built from local intent, so an
  /// unsettled cart sync cannot change what was ordered; it only means the
  /// server-side cart was still catching up.
  final bool drainSettled;

  /// Nothing left to do — the outcome is known.
  bool get isTerminal =>
      state == CheckoutAttemptState.confirmed ||
      state == CheckoutAttemptState.failed;

  /// Sent, outcome not established. These are what reconciliation resolves.
  bool get needsReconciliation =>
      state == CheckoutAttemptState.dispatched ||
      state == CheckoutAttemptState.unknown;

  /// The POST provably never went out, so the attempt can be dropped and the
  /// cart handed straight back to the user.
  bool get isAbandonable => state == CheckoutAttemptState.preparing;

  /// True once the attempt has been outstanding longer than [grace], at which
  /// point "no matching order on the server" is trustworthy rather than just
  /// a race with WooCommerce finishing the write.
  bool isOlderThan(Duration grace, DateTime now) =>
      now.difference(dispatchedAt ?? createdAt) >= grace;

  int get totalQuantity => lines.fold(0, (sum, l) => sum + l.quantity);

  /// Absolute quantities, the shape [CartCoordinator.setExactLines] expects.
  Map<int, int> get quantityByProductId => {
        for (final l in lines) l.productId: l.quantity,
      };

  CheckoutAttempt copyWith({
    CheckoutAttemptState? state,
    List<CheckoutAttemptLine>? lines,
    DateTime? updatedAt,
    DateTime? dispatchedAt,
    DateTime? resolvedAt,
    int? orderId,
    String? orderNumber,
    String? error,
    bool clearError = false,
    String? localRef,
    String? totalDisplay,
    int? lookupAttempts,
    bool? drainSettled,
  }) {
    return CheckoutAttempt(
      attemptId: attemptId,
      clientOrderKey: clientOrderKey,
      userKey: userKey,
      state: state ?? this.state,
      lines: lines ?? this.lines,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      dispatchedAt: dispatchedAt ?? this.dispatchedAt,
      resolvedAt: resolvedAt ?? this.resolvedAt,
      orderId: orderId ?? this.orderId,
      orderNumber: orderNumber ?? this.orderNumber,
      error: clearError ? null : (error ?? this.error),
      localRef: localRef ?? this.localRef,
      totalDisplay: totalDisplay ?? this.totalDisplay,
      lookupAttempts: lookupAttempts ?? this.lookupAttempts,
      drainSettled: drainSettled ?? this.drainSettled,
    );
  }

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'attemptId': attemptId,
        'clientOrderKey': clientOrderKey,
        'userKey': userKey,
        'state': state.name,
        'lines': lines.map((l) => l.toJson()).toList(),
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': (updatedAt ?? DateTime.now()).toUtc().toIso8601String(),
        if (dispatchedAt != null)
          'dispatchedAt': dispatchedAt!.toUtc().toIso8601String(),
        if (resolvedAt != null)
          'resolvedAt': resolvedAt!.toUtc().toIso8601String(),
        if (orderId != null) 'orderId': orderId,
        if (orderNumber != null) 'orderNumber': orderNumber,
        if (error != null) 'error': error,
        if (localRef != null) 'localRef': localRef,
        if (totalDisplay != null) 'totalDisplay': totalDisplay,
        'lookupAttempts': lookupAttempts,
        'drainSettled': drainSettled,
      };

  /// Returns null for anything unparseable rather than throwing — a corrupt
  /// record must never block checkout or crash startup.
  static CheckoutAttempt? fromJson(Map<String, dynamic> j) {
    final id = j['attemptId']?.toString();
    if (id == null || id.isEmpty) return null;
    final created = DateTime.tryParse((j['createdAt'] ?? '').toString());
    if (created == null) return null;

    final lines = <CheckoutAttemptLine>[];
    final rawLines = j['lines'];
    if (rawLines is List) {
      for (final e in rawLines) {
        if (e is! Map<String, dynamic>) continue;
        final line = CheckoutAttemptLine.fromJson(e);
        if (line != null) lines.add(line);
      }
    }

    final state = CheckoutAttemptState.values.firstWhere(
      (s) => s.name == j['state']?.toString(),
      // An unrecognised state is treated as ambiguous, never as success:
      // guessing `confirmed` would clear a basket for an order that may not
      // exist.
      orElse: () => CheckoutAttemptState.unknown,
    );

    return CheckoutAttempt(
      attemptId: id,
      clientOrderKey: j['clientOrderKey']?.toString() ?? id,
      userKey: j['userKey']?.toString() ?? '',
      state: state,
      lines: lines,
      createdAt: created,
      updatedAt: DateTime.tryParse((j['updatedAt'] ?? '').toString()),
      dispatchedAt: DateTime.tryParse((j['dispatchedAt'] ?? '').toString()),
      resolvedAt: DateTime.tryParse((j['resolvedAt'] ?? '').toString()),
      orderId: _asIntOrNull(j['orderId']),
      orderNumber: j['orderNumber']?.toString(),
      error: j['error']?.toString(),
      localRef: j['localRef']?.toString(),
      totalDisplay: j['totalDisplay']?.toString(),
      lookupAttempts: _asInt(j['lookupAttempts']),
      drainSettled: j['drainSettled'] != false,
    );
  }

  /// A fresh attempt in [CheckoutAttemptState.preparing].
  factory CheckoutAttempt.starting({
    required String userKey,
    required List<CheckoutAttemptLine> lines,
    required DateTime now,
    String? totalDisplay,
    String? attemptId,
    bool drainSettled = true,
  }) {
    final id = attemptId ?? newAttemptId();
    return CheckoutAttempt(
      attemptId: id,
      clientOrderKey: id,
      userKey: userKey,
      state: CheckoutAttemptState.preparing,
      lines: lines,
      createdAt: now,
      updatedAt: now,
      totalDisplay: totalDisplay,
      drainSettled: drainSettled,
    );
  }

  static final Random _rand = Random();
  static int _counter = 0;

  /// Collision-resistant without pulling in a uuid dependency, matching the
  /// approach already used for cart mutation ids.
  static String newAttemptId() {
    final n = _counter++;
    return 'qco_${DateTime.now().microsecondsSinceEpoch}_${n}_'
        '${_rand.nextInt(1 << 20)}';
  }

  @override
  String toString() => 'CheckoutAttempt($attemptId ${state.name} '
      'lines=${lines.length} order=$orderId)';
}

int _asInt(Object? v) {
  if (v is int) return v;
  return int.tryParse(v?.toString() ?? '') ?? 0;
}

int? _asIntOrNull(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  return int.tryParse(v.toString());
}
