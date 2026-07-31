import '../../../services/cart_cache_service.dart';

/// Why a cart sync did no network work. None of these are failures.
enum CartSyncSkipReason {
  /// Another sync was already running; its result supersedes this call.
  alreadyInFlight,

  /// Throttled by the sync interval and not forced.
  throttled,

  /// Not signed in — the cart is local-only.
  guest,
}

/// Result of [CartSyncService.syncNow].
///
/// Replaces a nullable `CartCacheRecord?` return, which could not distinguish
/// "nothing to do" from "the request failed". Callers read `null` as failure,
/// so a genuinely empty cart — or a sync skipped because the periodic timer
/// happened to be mid-flight — surfaced to the user as a red
/// "Cart API unavailable" error.
sealed class CartSyncOutcome {
  const CartSyncOutcome();

  /// The cached record to render, when this outcome carries one.
  CartCacheRecord? get record => null;
}

/// Network sync completed. An **empty cart is a success**, not a failure.
class CartSyncSucceeded extends CartSyncOutcome {
  const CartSyncSucceeded(this._record);

  final CartCacheRecord _record;

  @override
  CartCacheRecord get record => _record;

  bool get isEmptyCart => _record.items.isEmpty;
}

/// No network work was attempted. Carries the last known cached record, if any.
class CartSyncSkipped extends CartSyncOutcome {
  const CartSyncSkipped(this.reason, [this._record]);

  final CartSyncSkipReason reason;
  final CartCacheRecord? _record;

  @override
  CartCacheRecord? get record => _record;
}

/// The sync was attempted and failed.
class CartSyncFailed extends CartSyncOutcome {
  const CartSyncFailed({
    required this.userMessage,
    this.debugDetail,
    this.transient = true,
    CartCacheRecord? record,
  }) : _record = record;

  /// Friendly, jargon-free copy safe to show in production.
  final String userMessage;

  /// Raw technical detail. Only surface under debug/QA builds.
  final String? debugDetail;

  final bool transient;
  final CartCacheRecord? _record;

  @override
  CartCacheRecord? get record => _record;
}
