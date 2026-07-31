import 'dart:async';

import '../../../config/cart_engine_config.dart';
import '../../../services/cart_cache_service.dart'
    show CartCacheRecord, CartSyncStatus;
import '../domain/cart_document.dart';
import '../domain/cart_item.dart';
import '../domain/cart_mutation.dart';
import '../domain/cart_sync_outcome.dart';
import 'cart_document_store.dart';
import 'cart_remote_gateway.dart';

/// Why a reconcile ran, for diagnostics.
enum ReconcileReason { manual, appResume, afterMutation, beforeCheckout, authChange, startup }

/// The single writer of cart state.
///
/// Design decisions worth knowing before changing anything here:
///
/// 1. **Absolute quantities, never increments.** `POST /cart/add-item`
///    increments server-side, so a request that succeeded but timed out
///    client-side would double the line on retry. Every gesture folds into an
///    absolute target, which makes every dispatch safe to replay.
/// 2. **Intent and the confirmed server view are separate.** [CartDocument.lines]
///    is what the user wants; [CartDocument.confirmed] is what the server last
///    said. A response is only allowed to overwrite intent for a product with
///    no pending mutation whose `lastLocalSeq` predates the dispatch — that
///    comparison is the stale-response guard.
/// 3. **Persist before returning.** A mutator's future completes only after the
///    document is on disk, so nothing can revert an accepted change.
/// 4. **One in-flight mutation.** The queue is strictly serialized.
class CartCoordinator {
  CartCoordinator({
    required CartRemoteGateway gateway,
    required Future<String> Function() userKeyProvider,
    CartDocumentStore? store,
    Future<void> Function(Duration)? delay,
    DateTime Function()? clock,
    bool autoDispatch = true,
  })  : _gateway = gateway,
        _userKey = userKeyProvider,
        _store = store ?? CartDocumentStore(),
        _delay = delay ?? _realDelay,
        _now = clock ?? DateTime.now,
        _autoDispatch = autoDispatch;

  static Future<void> _realDelay(Duration d) => Future<void>.delayed(d);

  final CartRemoteGateway _gateway;
  final Future<String> Function() _userKey;
  final CartDocumentStore _store;
  final Future<void> Function(Duration) _delay;
  final DateTime Function() _now;

  /// When false the engine never self-schedules a dispatch; callers drive it
  /// with [flush]. Tests use this to exercise coalescing deterministically.
  final bool _autoDispatch;

  /// Debounce token. Each new gesture invalidates the pending scheduled pump,
  /// so a burst of stepper taps dispatches once, after the burst ends.
  int _debounceToken = 0;

  final StreamController<CartDocument> _controller =
      StreamController<CartDocument>.broadcast();

  CartDocument _doc = CartDocument.empty('guest');
  bool _started = false;
  bool _disposed = false;
  bool _pumping = false;
  Future<void>? _startupSync;
  bool _reconcileInFlight = false;
  int _consecutiveNetworkFailures = 0;
  Timer? _heartbeat;

  /// Serializes every mutator so document reads/writes cannot interleave.
  Future<void> _opChain = Future<void>.value();

  Stream<CartDocument> get stream => _controller.stream;
  CartDocument get current => _doc;
  bool get isPaused =>
      _consecutiveNetworkFailures >= CartEngineConfig.offlinePauseThreshold;

  // ---------------------------------------------------------------- lifecycle

  Future<void> start({bool startHeartbeat = true}) async {
    if (_started) return;
    _started = true;
    await _enqueue(() async {
      final key = await _userKey();
      _doc = await _store.read(key);
      _releaseLeakedHold();
      _emit();
    });
    if (startHeartbeat) {
      _heartbeat = Timer.periodic(
        CartEngineConfig.heartbeat,
        (_) => reconcile(reason: ReconcileReason.manual).ignore(),
      );
    }
    // Refresh the server view before replaying anything, so dispatch has
    // current line keys to work with. Deliberately not awaited — startup must
    // not block on the network — but the future is retained so [flush] and
    // [drainForCheckout] can settle it.
    _startupSync = reconcile(force: true, reason: ReconcileReason.startup)
        .then((_) => _pump());
    unawaited(_startupSync!);
  }

  Future<void> ensureHydrated() => _enqueue(() async {});

  /// Settles startup sync, queued work and the dispatch queue.
  ///
  /// Public so the checkout barrier — and tests — can drive the engine to a
  /// quiescent state without waiting on the debounce timer.
  Future<void> flush() async {
    final startup = _startupSync;
    if (startup != null) {
      try {
        await startup;
      } catch (_) {
        // Startup sync failure is already recorded on the document.
      }
    }
    await _enqueue(() async {});
    await _pump();
  }

  /// Debounced dispatch. A newer gesture supersedes an earlier scheduled pump,
  /// which is what collapses rapid taps into a single network call.
  void _schedulePump() {
    if (!_autoDispatch) return;
    final token = ++_debounceToken;
    _delay(CartEngineConfig.coalesceWindow).then((_) {
      if (token != _debounceToken) return;
      _pump().ignore();
    });
  }

  /// Wakes the queue after a backoff. Without this a transient failure would
  /// park the mutation with nothing left to retry it.
  void _scheduleRetry(Duration backoff) {
    if (!_autoDispatch) return;
    _delay(backoff).then((_) => _pump().ignore());
  }

  void dispose() {
    _disposed = true;
    // Invalidate any scheduled debounce/retry wake-up.
    _debounceToken++;
    _heartbeat?.cancel();
    _heartbeat = null;
    _controller.close();
  }

  // ------------------------------------------------------------------ mutators

  /// Adds [quantity] to the current intent for [productId].
  Future<void> add(int productId, {int quantity = 1}) {
    if (quantity <= 0) return Future<void>.value();
    return _enqueue(() async {
      await _applyTarget(productId, _doc.quantityOf(productId) + quantity);
    });
  }

  Future<void> setQuantity(int productId, int quantity) => _enqueue(() async {
        await _applyTarget(productId, quantity < 0 ? 0 : quantity);
      });

  Future<void> remove(int productId) => _enqueue(() async {
        await _applyTarget(productId, 0);
      });

  Future<void> clear() => _enqueue(() async {
        if (_holdActive) return;
        final seq = _doc.localSequence + 1;
        final mutation = CartMutation(
          mutationId: CartMutation.newMutationId(),
          localSequence: seq,
          cartRevision: _doc.revision + 1,
          op: CartMutationOp.clearAll,
          productId: 0,
          targetQuantity: 0,
          createdAt: _now(),
        );
        _doc = _doc.copyWith(
          lines: const [],
          revision: _doc.revision + 1,
          localSequence: seq,
          // A clear supersedes everything queued before it.
          pending: [mutation],
          syncStatus: CartSyncStatus.pending,
          clearLastSyncError: true,
        );
        await _persist();
      });

  /// Replaces intent wholesale with absolute quantities.
  ///
  /// Used by reorder and by pulling a cart back out of the WebView. Reorder
  /// previously called an incrementing `add` per line, which silently doubled
  /// any SKU already in the basket.
  Future<void> setExactLines(Map<int, int> quantityByProductId) =>
      _enqueue(() async {
        if (_holdActive) return;
        var seq = _doc.localSequence;
        final lines = <CartLine>[];
        final pending = _doc.pending
            .where((m) => m.state == CartMutationState.failedPermanent)
            .toList();

        final touched = <int>{
          ...quantityByProductId.keys,
          ..._doc.lines.map((l) => l.productId),
        };

        for (final pid in touched) {
          final target = quantityByProductId[pid] ?? 0;
          seq += 1;
          if (target > 0) {
            lines.add(CartLine(
              productId: pid,
              quantity: target,
              lastLocalSeq: seq,
            ));
          }
          if (_doc.quantityOf(pid) != target) {
            pending.add(_newSetQuantity(pid, target, seq));
          }
        }

        _doc = _doc.copyWith(
          lines: lines,
          revision: _doc.revision + 1,
          localSequence: seq,
          pending: pending,
          syncStatus:
              pending.isEmpty ? _doc.syncStatus : CartSyncStatus.pending,
        );
        await _persist();
      });

  /// Merges a guest basket into the signed-in document without any network
  /// round trip, so login is not blocked on cart sync.
  Future<void> adoptCart(Map<int, int> quantityByProductId) => _enqueue(() async {
        if (quantityByProductId.isEmpty) return;
        var seq = _doc.localSequence;
        final merged = <int, int>{
          for (final l in _doc.lines) l.productId: l.quantity,
        };
        for (final entry in quantityByProductId.entries) {
          if (entry.value <= 0) continue;
          // Take the larger of the two rather than summing: adopting twice
          // (auth listener + explicit login call) must not double the basket.
          final existing = merged[entry.key] ?? 0;
          merged[entry.key] = entry.value > existing ? entry.value : existing;
        }

        final pending = List<CartMutation>.from(_doc.pending);
        final lines = <CartLine>[];
        for (final entry in merged.entries) {
          seq += 1;
          lines.add(CartLine(
            productId: entry.key,
            quantity: entry.value,
            lastLocalSeq: seq,
          ));
          pending.add(_newSetQuantity(entry.key, entry.value, seq));
        }

        _doc = _doc.copyWith(
          lines: lines,
          revision: _doc.revision + 1,
          localSequence: seq,
          pending: pending,
          syncStatus: CartSyncStatus.pending,
        );
        await _persist();
      });

  /// Switches to another user's document (login, logout, account change).
  Future<void> onUserChanged() => _enqueue(() async {
        final key = await _userKey();
        if (key == _doc.userKey) return;
        _doc = await _store.read(key);
        _releaseLeakedHold();
        _emit();
      });

  // ---------------------------------------------------------------- reconcile

  Future<CartSyncOutcome> reconcile({
    bool force = false,
    ReconcileReason reason = ReconcileReason.manual,
  }) async {
    if (_disposed || _reconcileInFlight) {
      return CartSyncSkipped(CartSyncSkipReason.alreadyInFlight, _asRecord());
    }
    if (!_gateway.isSignedIn) {
      return CartSyncSkipped(CartSyncSkipReason.guest, _asRecord());
    }
    if (!force && isPaused) {
      return CartSyncSkipped(CartSyncSkipReason.throttled, _asRecord());
    }

    _reconcileInFlight = true;
    final dispatchedAtSequence = _doc.localSequence;
    try {
      await _gateway.ensureSession();
      final result = await _gateway.fetchCart();
      if (!result.ok) {
        _noteNetworkOutcome(transient: result.isTransient);
        await _enqueue(() async {
          _doc = _doc.copyWith(
            syncStatus: CartSyncStatus.failed,
            lastSyncError: _friendlyError,
          );
          await _persist();
        });
        return CartSyncFailed(
          userMessage: _friendlyError,
          debugDetail: result.detail,
          transient: result.isTransient,
          record: _asRecord(),
        );
      }

      _noteNetworkOutcome(transient: false);
      await _enqueue(() async {
        _absorbServerCart(result.cartJson, dispatchedAtSequence);
        await _persist();
      });
      // An empty cart is a successful answer, not a failure.
      return CartSyncSucceeded(_asRecord());
    } finally {
      _reconcileInFlight = false;
    }
  }

  /// Waits for the queue to drain before an order is submitted.
  ///
  /// Returns false when work is still outstanding, so the caller can refuse to
  /// submit rather than ordering against an unconfirmed basket.
  Future<bool> drainForCheckout({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final deadline = _now().add(timeout);
    while (_doc.hasPendingWork && _now().isBefore(deadline)) {
      await _pump();
      if (!_doc.hasPendingWork) break;
      await _delay(const Duration(milliseconds: 100));
    }
    return !_doc.hasPendingWork;
  }

  // ------------------------------------------------------------ checkout hold

  Future<void> beginCheckoutHold(String attemptId) => _enqueue(() async {
        _doc = _doc.copyWith(
          checkoutHoldId: attemptId,
          checkoutHoldAt: _now(),
        );
        await _persist();
      });

  Future<void> endCheckoutHold(
    String attemptId, {
    required bool clearCart,
  }) =>
      _enqueue(() async {
        if (_doc.checkoutHoldId != attemptId && _doc.checkoutHoldId != null) {
          return;
        }
        _doc = _doc.copyWith(clearCheckoutHold: true);
        if (clearCart) {
          _doc = _doc.copyWith(
            lines: const [],
            confirmed: const ConfirmedCart(),
            pending: const [],
            revision: _doc.revision + 1,
            syncStatus: CartSyncStatus.synced,
            clearLastSyncError: true,
          );
        }
        await _persist();
      });

  bool get _holdActive =>
      _doc.holdIsActive(CartEngineConfig.checkoutHoldTtl, _now());

  void _releaseLeakedHold() {
    if (_doc.checkoutHoldId != null && !_holdActive) {
      // A crash or an exception path that skipped endCheckoutHold must not
      // freeze the basket permanently.
      _doc = _doc.copyWith(clearCheckoutHold: true);
    }
  }

  // -------------------------------------------------------------- queue pump

  /// Drains the queue. At most one mutation is in flight at any time.
  Future<void> _pump() async {
    if (_pumping || _disposed) return;
    _pumping = true;
    try {
      while (true) {
        if (_disposed || !_gateway.isSignedIn) return;
        final mutation = _nextReady();
        if (mutation == null) return;

        await _enqueue(() async {
          _doc = _doc.copyWith(
            pending: _replace(
              mutation.copyWith(state: CartMutationState.inFlight),
            ),
          );
        });

        final dispatchedAtSequence = _doc.localSequence;
        final result = await _dispatch(mutation);

        if (result.ok) {
          _noteNetworkOutcome(transient: false);
          await _enqueue(() async {
            _doc = _doc.copyWith(pending: _without(mutation.mutationId));
            _absorbServerCart(result.cartJson, dispatchedAtSequence);
            _doc = _doc.copyWith(
              syncStatus: _doc.hasPendingWork
                  ? CartSyncStatus.pending
                  : CartSyncStatus.synced,
              clearLastSyncError: true,
            );
            // No dispatch reschedule: this loop continues to the next item.
            await _persist(dispatch: false);
          });
          continue;
        }

        final retries = mutation.retryCount + 1;
        final exhausted = retries >= CartEngineConfig.maxAttempts;
        final givingUp = !result.isTransient || exhausted;
        final backoff = CartEngineConfig.backoffFor(retries - 1);
        _noteNetworkOutcome(transient: result.isTransient);

        await _enqueue(() async {
          final updated = givingUp
              ? mutation.copyWith(
                  state: CartMutationState.failedPermanent,
                  retryCount: retries,
                  lastError: result.detail,
                )
              : mutation.copyWith(
                  state: CartMutationState.queued,
                  retryCount: retries,
                  nextAttemptAt: _now().add(backoff),
                  lastError: result.detail,
                );
          _doc = _doc.copyWith(
            pending: _replace(updated),
            syncStatus: CartSyncStatus.failed,
            lastSyncError: _friendlyError,
          );
          await _persist(dispatch: false);
        });

        if (givingUp) {
          // Permanently failed: skip it and keep draining the rest.
          continue;
        }

        // Transient: stop the loop and wake up once the backoff has elapsed.
        // Looping here would burn the whole retry budget in microseconds.
        _scheduleRetry(backoff);
        return;
      }
    } finally {
      _pumping = false;
    }
  }

  Future<GatewayResult> _dispatch(CartMutation m) async {
    try {
      if (m.op == CartMutationOp.clearAll) return await _gateway.clearCart();
      return await _gateway.setQuantity(
        m.productId,
        targetQuantity: m.targetQuantity,
        knownKey: _doc.confirmed?.cartItemKeyByProductId[m.productId],
      );
    } catch (e) {
      return GatewayResult.transientFailure(e.toString());
    }
  }

  CartMutation? _nextReady() {
    final now = _now();
    for (final m in _doc.pending) {
      if (m.state == CartMutationState.inFlight) return null;
      if (m.isReady(now)) return m;
    }
    return null;
  }

  // ---------------------------------------------------------------- internals

  Future<void> _applyTarget(int productId, int target) async {
    if (_holdActive) return;
    final seq = _doc.localSequence + 1;
    final lines = <CartLine>[];
    var found = false;
    for (final l in _doc.lines) {
      if (l.productId != productId) {
        lines.add(l);
        continue;
      }
      found = true;
      if (target > 0) {
        lines.add(l.copyWith(quantity: target, lastLocalSeq: seq));
      }
    }
    if (!found && target > 0) {
      lines.add(CartLine(
        productId: productId,
        quantity: target,
        lastLocalSeq: seq,
      ));
    }

    _doc = _doc.copyWith(
      lines: lines,
      revision: _doc.revision + 1,
      localSequence: seq,
      pending: _coalesce(productId, target, seq),
      syncStatus: CartSyncStatus.pending,
      clearLastSyncError: true,
    );
    await _persist();
  }

  /// Folds a new target onto any queued mutation for the same product so rapid
  /// taps produce exactly one network call.
  List<CartMutation> _coalesce(int productId, int target, int seq) {
    final out = <CartMutation>[];
    var merged = false;
    for (final m in _doc.pending) {
      final sameProduct =
          m.op == CartMutationOp.setQuantity && m.productId == productId;
      // An in-flight mutation cannot be rewritten; queue a follow-up instead.
      if (sameProduct &&
          m.state == CartMutationState.queued &&
          !merged) {
        out.add(m.copyWith(
          targetQuantity: target,
          localSequence: seq,
          state: CartMutationState.queued,
          clearNextAttemptAt: true,
          retryCount: 0,
          clearLastError: true,
        ));
        merged = true;
        continue;
      }
      if (sameProduct && m.state == CartMutationState.failedPermanent) {
        // Superseded by a fresh intent; drop it.
        continue;
      }
      out.add(m);
    }
    if (!merged) out.add(_newSetQuantity(productId, target, seq));
    return out;
  }

  CartMutation _newSetQuantity(int productId, int target, int seq) =>
      CartMutation(
        mutationId: CartMutation.newMutationId(),
        localSequence: seq,
        cartRevision: _doc.revision + 1,
        op: CartMutationOp.setQuantity,
        productId: productId,
        targetQuantity: target,
        createdAt: _now(),
      );

  List<CartMutation> _replace(CartMutation updated) => [
        for (final m in _doc.pending)
          if (m.mutationId == updated.mutationId) updated else m,
      ];

  List<CartMutation> _without(String mutationId) =>
      _doc.pending.where((m) => m.mutationId != mutationId).toList();

  /// Folds a server cart body into [CartDocument.confirmed], and into intent
  /// only where doing so cannot discard a newer local change.
  void _absorbServerCart(Map<String, dynamic>? cartJson, int dispatchedAtSequence) {
    if (cartJson == null) return;

    final serverLines = <int, int>{};
    final keys = <int, String>{};
    final raw = cartJson['items'];
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        final id = e['id'];
        final pid = id is int ? id : int.tryParse(id?.toString() ?? '');
        if (pid == null || pid <= 0) continue;
        final q = e['quantity'];
        final qty = q is int ? q : int.tryParse(q?.toString() ?? '') ?? 0;
        serverLines[pid] = qty;
        final key = e['key']?.toString();
        if (key != null && key.isNotEmpty) keys[pid] = key;
      }
    }

    _doc = _doc.copyWith(
      confirmed: ConfirmedCart(
        lines: [
          for (final entry in serverLines.entries)
            if (entry.value > 0)
              CartItem(productId: entry.key, quantity: entry.value),
        ],
        snapshotJson: cartJson,
        cartItemKeyByProductId: keys,
        fetchedAt: _now(),
      ),
    );

    final adopted = <CartLine>[];
    final seen = <int>{};

    for (final line in _doc.lines) {
      seen.add(line.productId);
      final canAdopt = !_doc.hasPendingFor(line.productId) &&
          line.lastLocalSeq <= dispatchedAtSequence;
      if (!canAdopt) {
        // Newer local intent wins; this is the stale-response guard.
        adopted.add(line);
        continue;
      }
      final serverQty = serverLines[line.productId] ?? 0;
      if (serverQty > 0) {
        adopted.add(line.copyWith(quantity: serverQty));
      }
      // serverQty == 0 with no pending work ⇒ the line is genuinely gone.
    }

    // Lines the server knows about that we do not (added on the website).
    for (final entry in serverLines.entries) {
      if (seen.contains(entry.key) || entry.value <= 0) continue;
      if (_doc.hasPendingFor(entry.key)) continue;
      adopted.add(CartLine(productId: entry.key, quantity: entry.value));
    }

    _doc = _doc.copyWith(lines: adopted);
  }

  void _noteNetworkOutcome({required bool transient}) {
    if (transient) {
      _consecutiveNetworkFailures++;
    } else {
      _consecutiveNetworkFailures = 0;
    }
  }

  /// Runs [action] on the serial chain, then emits the resulting document.
  Future<void> _enqueue(Future<void> Function() action) {
    final next = _opChain.then((_) => action());
    _opChain = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  Future<void> _persist({bool dispatch = true}) async {
    await _store.write(_doc);
    _emit();
    if (dispatch) _schedulePump();
  }

  void _emit() {
    if (!_controller.isClosed) _controller.add(_doc);
  }

  /// Projects the document into the legacy record shape that
  /// [CartSyncOutcome] carries, so existing callers keep working.
  CartCacheRecord _asRecord() => CartCacheRecord(
        items: _doc.itemsView,
        snapshotJson: _doc.confirmed?.snapshotJson,
        syncStatus: _doc.syncStatus,
        updatedAt: _doc.updatedAt,
        lastSyncAt: _doc.confirmed?.fetchedAt,
        lastSyncError: _doc.lastSyncError,
      );

  static const String _friendlyError =
      "We're having trouble reaching our cart server. We'll keep trying.";
}
