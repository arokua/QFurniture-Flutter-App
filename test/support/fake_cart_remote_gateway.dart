import 'dart:async';

import 'package:Qtoys/features/cart/data/cart_remote_gateway.dart';

/// A recorded gateway call.
class GatewayCall {
  GatewayCall(this.kind, {this.productId, this.targetQuantity, this.knownKey});

  final String kind; // 'fetch' | 'setQuantity' | 'clear'
  final int? productId;
  final int? targetQuantity;
  final String? knownKey;

  @override
  String toString() => kind == 'setQuantity'
      ? 'setQuantity(p$productId -> $targetQuantity, key=$knownKey)'
      : kind;
}

/// Scripted gateway with a simulated server cart.
///
/// Hand-written rather than generated because the important scenarios are
/// about *timing* — holding one response open while a newer mutation is
/// enqueued — which is far easier to express with explicit [Completer]s than
/// with a mocking DSL.
class FakeCartRemoteGateway implements CartRemoteGateway {
  FakeCartRemoteGateway({this.signedIn = true});

  /// Mutable so a test can simulate sign-out mid-flight.
  bool signedIn;

  @override
  bool get isSignedIn => signedIn;

  /// Simulated server-side cart: productId -> quantity.
  final Map<int, int> serverCart = <int, int>{};

  /// Line keys the fake hands out, mirroring Store API `items[].key`.
  final Map<int, String> serverKeys = <int, String>{};

  final List<GatewayCall> calls = <GatewayCall>[];

  int ensureSessionCalls = 0;

  /// Queued outcomes for the next `setQuantity` calls. When empty, the call
  /// succeeds and mutates [serverCart].
  final List<GatewayResult> scriptedSetQuantity = <GatewayResult>[];

  /// Queued outcomes for the next `fetchCart` calls.
  final List<GatewayResult> scriptedFetch = <GatewayResult>[];

  /// When set, `setQuantity` applies to the server cart but then returns the
  /// scripted failure — models "succeeded server-side, timed out client-side".
  bool applyThenFail = false;

  /// Gate that lets a test hold a response open.
  Completer<void>? gate;

  @override
  Future<void> ensureSession() async {
    ensureSessionCalls++;
  }

  @override
  Future<GatewayResult> fetchCart() async {
    calls.add(GatewayCall('fetch'));
    await _awaitGate();
    if (scriptedFetch.isNotEmpty) return scriptedFetch.removeAt(0);
    return GatewayResult.success(cartJson: cartJson());
  }

  @override
  Future<GatewayResult> setQuantity(
    int productId, {
    required int targetQuantity,
    String? knownKey,
  }) async {
    calls.add(GatewayCall(
      'setQuantity',
      productId: productId,
      targetQuantity: targetQuantity,
      knownKey: knownKey,
    ));
    await _awaitGate();

    if (scriptedSetQuantity.isNotEmpty) {
      final scripted = scriptedSetQuantity.removeAt(0);
      if (applyThenFail) _applyToServer(productId, targetQuantity);
      if (!scripted.ok) return scripted;
    }

    _applyToServer(productId, targetQuantity);
    return GatewayResult.success(cartJson: cartJson());
  }

  @override
  Future<GatewayResult> clearCart() async {
    calls.add(GatewayCall('clear'));
    await _awaitGate();
    serverCart.clear();
    serverKeys.clear();
    return GatewayResult.success(cartJson: cartJson());
  }

  void _applyToServer(int productId, int target) {
    // Absolute assignment — this is precisely why replay is safe.
    if (target <= 0) {
      serverCart.remove(productId);
      serverKeys.remove(productId);
    } else {
      serverCart[productId] = target;
      serverKeys.putIfAbsent(productId, () => 'key-$productId');
    }
  }

  Future<void> _awaitGate() async {
    final g = gate;
    if (g != null) await g.future;
  }

  /// Store API shaped cart body.
  Map<String, dynamic> cartJson() => {
        'items': [
          for (final entry in serverCart.entries)
            {
              'id': entry.key,
              'key': serverKeys[entry.key] ?? 'key-${entry.key}',
              'quantity': entry.value,
              'name': 'Product ${entry.key}',
              'prices': {
                'price': '1000',
                'currency_minor_unit': 2,
                'currency_symbol': r'$',
              },
              'totals': {'line_total': '${1000 * entry.value}'},
            },
        ],
        'items_count': serverCart.values.fold(0, (a, b) => a + b),
        'totals': {
          'total_price': '${serverCart.values.fold(0, (a, b) => a + b) * 1000}',
          'total_items': '${serverCart.values.fold(0, (a, b) => a + b) * 1000}',
          'currency_minor_unit': 2,
          'currency_code': 'AUD',
          'currency_symbol': r'$',
        },
      };

  List<GatewayCall> get setQuantityCalls =>
      calls.where((c) => c.kind == 'setQuantity').toList();

  int get fetchCount => calls.where((c) => c.kind == 'fetch').length;

  void resetCalls() => calls.clear();
}
