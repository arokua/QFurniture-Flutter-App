import 'dart:math';

/// What a queued mutation does.
///
/// There is deliberately **no `add` operation**. WooCommerce's
/// `POST /cart/add-item` *increments* server-side, which makes it the only
/// non-idempotent cart call and the direct cause of double-quantity on an
/// ambiguous timeout. Every gesture is therefore folded into an absolute
/// target quantity, so replaying a mutation converges instead of accumulating.
enum CartMutationOp {
  /// Drive one product to [CartMutation.targetQuantity]. Zero means remove.
  setQuantity,

  /// Empty the whole cart.
  clearAll,
}

enum CartMutationState { queued, inFlight, failedPermanent }

/// Why a dispatch failed, which decides whether it is worth retrying.
enum MutationErrorClass {
  /// Timeout, socket error, 5xx, 429 — retry with backoff.
  transient,

  /// 4xx validation (out of stock, product gone) — retrying cannot help.
  permanent,
}

class CartMutation {
  CartMutation({
    required this.mutationId,
    required this.localSequence,
    required this.cartRevision,
    required this.op,
    required this.productId,
    required this.targetQuantity,
    required this.createdAt,
    this.retryCount = 0,
    this.nextAttemptAt,
    this.state = CartMutationState.queued,
    this.lastError,
  });

  final String mutationId;

  /// Monotonic per-document counter. Used to reject responses that were issued
  /// before a newer local change.
  final int localSequence;

  final int cartRevision;
  final CartMutationOp op;

  /// Zero for [CartMutationOp.clearAll].
  final int productId;

  final int targetQuantity;
  final DateTime createdAt;
  final int retryCount;
  final DateTime? nextAttemptAt;
  final CartMutationState state;
  final String? lastError;

  /// Idempotency key. Stable across retries of the same logical mutation.
  String get idempotencyKey => mutationId;

  bool get isTerminal => state == CartMutationState.failedPermanent;

  bool isReady(DateTime now) {
    if (state == CartMutationState.failedPermanent) return false;
    final next = nextAttemptAt;
    return next == null || !now.isBefore(next);
  }

  CartMutation copyWith({
    int? localSequence,
    int? cartRevision,
    int? targetQuantity,
    int? retryCount,
    DateTime? nextAttemptAt,
    bool clearNextAttemptAt = false,
    CartMutationState? state,
    String? lastError,
    bool clearLastError = false,
  }) {
    return CartMutation(
      mutationId: mutationId,
      localSequence: localSequence ?? this.localSequence,
      cartRevision: cartRevision ?? this.cartRevision,
      op: op,
      productId: productId,
      targetQuantity: targetQuantity ?? this.targetQuantity,
      createdAt: createdAt,
      retryCount: retryCount ?? this.retryCount,
      nextAttemptAt:
          clearNextAttemptAt ? null : (nextAttemptAt ?? this.nextAttemptAt),
      state: state ?? this.state,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
    );
  }

  Map<String, dynamic> toJson() => {
        'mutationId': mutationId,
        'localSequence': localSequence,
        'cartRevision': cartRevision,
        'op': op.name,
        'productId': productId,
        'targetQuantity': targetQuantity,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'retryCount': retryCount,
        if (nextAttemptAt != null)
          'nextAttemptAt': nextAttemptAt!.toUtc().toIso8601String(),
        'state': state.name,
        if (lastError != null) 'lastError': lastError,
      };

  static CartMutation? fromJson(Map<String, dynamic> j) {
    final id = j['mutationId']?.toString();
    if (id == null || id.isEmpty) return null;
    final op = CartMutationOp.values.firstWhere(
      (o) => o.name == j['op']?.toString(),
      orElse: () => CartMutationOp.setQuantity,
    );
    final created = DateTime.tryParse((j['createdAt'] ?? '').toString());
    if (created == null) return null;

    var state = CartMutationState.values.firstWhere(
      (s) => s.name == j['state']?.toString(),
      orElse: () => CartMutationState.queued,
    );
    // A mutation that was in flight when the process died is safe to replay:
    // dispatch is idempotent by construction (absolute target quantities).
    if (state == CartMutationState.inFlight) state = CartMutationState.queued;

    return CartMutation(
      mutationId: id,
      localSequence: _asInt(j['localSequence']),
      cartRevision: _asInt(j['cartRevision']),
      op: op,
      productId: _asInt(j['productId']),
      targetQuantity: _asInt(j['targetQuantity']),
      createdAt: created,
      retryCount: _asInt(j['retryCount']),
      nextAttemptAt: DateTime.tryParse((j['nextAttemptAt'] ?? '').toString()),
      state: state,
      lastError: j['lastError']?.toString(),
    );
  }

  static int _asInt(Object? v) {
    if (v is int) return v;
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static final Random _rand = Random();
  static int _counter = 0;

  /// Collision-resistant without pulling in a uuid dependency.
  static String newMutationId() {
    final n = _counter++;
    return '${DateTime.now().microsecondsSinceEpoch}-$n-${_rand.nextInt(1 << 20)}';
  }

  @override
  String toString() =>
      'CartMutation(${op.name} p$productId -> $targetQuantity, '
      'seq=$localSequence, retries=$retryCount, ${state.name})';
}
