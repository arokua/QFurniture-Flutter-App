import 'dart:async';
import 'dart:io';

import '../../../config/store_cart_api_service.dart';
import '../../../services/app_log.dart';
import '../domain/cart_mutation.dart';

/// Outcome of one remote cart call.
class GatewayResult {
  const GatewayResult._({
    required this.ok,
    this.cartJson,
    this.errorClass,
    this.detail,
  });

  const GatewayResult.success({Map<String, dynamic>? cartJson})
      : this._(ok: true, cartJson: cartJson);

  const GatewayResult.transientFailure(String detail)
      : this._(
          ok: false,
          errorClass: MutationErrorClass.transient,
          detail: detail,
        );

  const GatewayResult.permanentFailure(String detail)
      : this._(
          ok: false,
          errorClass: MutationErrorClass.permanent,
          detail: detail,
        );

  final bool ok;

  /// Full cart body when the call returned one, so a mutation response can
  /// update the confirmed view without a follow-up GET.
  final Map<String, dynamic>? cartJson;

  final MutationErrorClass? errorClass;
  final String? detail;

  bool get isTransient => errorClass == MutationErrorClass.transient;
}

/// Everything the cart engine needs from the network.
///
/// This exists so the coordinator can be exercised with a scripted fake:
/// holding a response open while a newer mutation is enqueued is the crux of
/// the stale-response tests, and that is impractical against the real client.
abstract class CartRemoteGateway {
  /// True when a signed-in session exists; the engine stays local-only when not.
  bool get isSignedIn;

  /// `GET /wc/store/v1/cart`.
  Future<GatewayResult> fetchCart();

  /// Drive one product to an absolute quantity (0 removes it).
  Future<GatewayResult> setQuantity(
    int productId, {
    required int targetQuantity,
    String? knownKey,
  });

  /// Empty the whole cart.
  Future<GatewayResult> clearCart();

  /// Refresh credentials before a batch of work.
  Future<void> ensureSession();
}

/// Production gateway backed by [StoreCartApiService].
class StoreCartApiGateway implements CartRemoteGateway {
  StoreCartApiGateway({
    required bool Function() isSignedInProvider,
    required Future<void> Function() ensureSessionCallback,
    StoreCartApiService? api,
  })  : _isSignedIn = isSignedInProvider,
        _ensureSession = ensureSessionCallback,
        _api = api ?? StoreCartApiService.instance;

  final bool Function() _isSignedIn;
  final Future<void> Function() _ensureSession;
  final StoreCartApiService _api;

  @override
  bool get isSignedIn => _isSignedIn();

  @override
  Future<void> ensureSession() => _ensureSession();

  @override
  Future<GatewayResult> fetchCart() async {
    final op = AppLog.begin('cart.fetch', fields: {'endpoint': 'store/v1/cart'});
    try {
      final res = await _api.fetchFullCart();
      if (!res.success || res.data == null) {
        op.end(result: LogResult.transient, fields: {'reason': 'no-data'});
        return const GatewayResult.transientFailure('cart fetch unavailable');
      }
      op.end(result: LogResult.ok);
      return GatewayResult.success(cartJson: res.data);
    } catch (e) {
      op.end(result: LogResult.transient, fields: {'reason': _describe(e)});
      return GatewayResult.transientFailure(_describe(e));
    }
  }

  @override
  Future<GatewayResult> setQuantity(
    int productId, {
    required int targetQuantity,
    String? knownKey,
  }) async {
    final op = AppLog.begin('cart.setQuantity', fields: {
      'endpoint': 'store/v1/cart',
      'productId': productId,
      'target': targetQuantity,
    });
    try {
      final ok = await _api.updateOrAddByProductId(
        productId,
        targetQuantity: targetQuantity,
        knownKey: knownKey,
      );
      if (!ok) {
        // The Store API client collapses non-2xx to `false`, so the class of
        // error is not recoverable here. Treat it as transient and let the
        // bounded retry budget stop the loop.
        op.end(result: LogResult.transient, fields: {'reason': 'rejected'});
        return const GatewayResult.transientFailure('cart update rejected');
      }
      op.end(result: LogResult.ok);
      return const GatewayResult.success();
    } catch (e) {
      op.end(result: LogResult.transient, fields: {'reason': _describe(e)});
      return GatewayResult.transientFailure(_describe(e));
    }
  }

  @override
  Future<GatewayResult> clearCart() async {
    final op = AppLog.begin('cart.clear', fields: {'endpoint': 'store/v1/cart'});
    try {
      final ok = await _api.clearCart();
      op.end(result: ok ? LogResult.ok : LogResult.transient);
      return ok
          ? const GatewayResult.success()
          : const GatewayResult.transientFailure('cart clear rejected');
    } catch (e) {
      op.end(result: LogResult.transient, fields: {'reason': _describe(e)});
      return GatewayResult.transientFailure(_describe(e));
    }
  }

  static String _describe(Object e) {
    if (e is TimeoutException) return 'timeout';
    if (e is SocketException) return 'network unavailable';
    return e.runtimeType.toString();
  }
}
