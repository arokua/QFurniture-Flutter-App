import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../config/store_cart_api_service.dart';
import '../../../services/auth_service.dart';
import '../domain/cart_item.dart';
import 'store_cart_json.dart';
import 'store_cart_snapshot.dart';

/// Full WooCommerce Store API cart (`GET /wc/store/v1/cart`).
/// Intentionally does not [watch] [cartProvider] — invalidate explicitly (cart screen open, checkout).
/// Does NOT guard on local cart.isEmpty: the server may have items even when local state is empty.
final storeCartFullProvider =
    FutureProvider.autoDispose<StoreCartApiSnapshot?>((ref) async {
  if (!AuthService.instance.isSignedIn) return null;
  final r = await StoreCartApiService.instance.fetchFullCart();
  if (!r.success || r.data == null) return null;
  return StoreCartApiSnapshot.fromCartJson(r.data!);
});

class CartNotifier extends StateNotifier<List<CartItem>> {
  static String _guestKey() => 'cart_items_guest';

  static String _keyForEmail(String email) =>
      'cart_items_${email.trim().toLowerCase()}';

  static String _storageKey() {
    final e = AuthService.instance.currentSession?.email.trim().toLowerCase();
    if (e == null || e.isEmpty) return _guestKey();
    return _keyForEmail(e);
  }

  /// Completes after local prefs load (no automatic remote merge).
  late final Future<void> _loadFuture;

  CartNotifier() : super([]) {
    AuthService.instance.addListener(_onAuthChanged);
    _loadFuture = _loadCart();
  }

  @override
  void dispose() {
    AuthService.instance.removeListener(_onAuthChanged);
    super.dispose();
  }

  Future<void> ensureHydrated() => _loadFuture;

  void _onAuthChanged() {
    Future.microtask(_handleAuthChanged);
  }

  /// Guest prefs → user key when the user has no saved cart; preserves in-memory lines at login.
  Future<void> _handleAuthChanged() async {
    final session = AuthService.instance.currentSession;
    final prefs = await SharedPreferences.getInstance();
    if (session != null) {
      final email = session.email.trim().toLowerCase();
      if (email.isEmpty) {
        await _reloadFromDisk();
        return;
      }
      final userKey = _keyForEmail(email);
      final guestKey = _guestKey();
      final rawUser = prefs.getString(userKey);
      final rawGuest = prefs.getString(guestKey);
      final userEmpty = rawUser == null || rawUser.isEmpty;
      final inMemory = List<CartItem>.from(state);

      if (userEmpty) {
        if (rawGuest != null && rawGuest.isNotEmpty) {
          await prefs.setString(userKey, rawGuest);
          await prefs.remove(guestKey);
        } else if (inMemory.isNotEmpty) {
          state = inMemory;
          await _saveCart();
          await prefs.remove(guestKey);
        }
      }
    }
    await _reloadFromDisk();
  }

  Future<void> _loadCart() async {
    await _reloadFromDisk();
  }

  Future<void> _reloadFromDisk() async {
    final prefs = await SharedPreferences.getInstance();
    final key = _storageKey();
    final raw = prefs.getString(key);
    if (raw == null) {
      state = [];
      return;
    }
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final decoded = list
          .map((e) => CartItem(
                productId: e['productId'] as int,
                quantity: e['quantity'] as int,
              ))
          .toList();
      state = decoded;
    } catch (_) {
      state = [];
    }
  }

  Future<void> _saveCart() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(state.map((e) => {
      'productId': e.productId,
      'quantity': e.quantity,
    }).toList());
    await prefs.setString(_storageKey(), raw);
  }

  void add(int productId, {int quantity = 1}) {
    final i = state.indexWhere((e) => e.productId == productId);
    if (i >= 0) {
      state = [
        ...state.sublist(0, i),
        state[i].copyWith(quantity: state[i].quantity + quantity),
        ...state.sublist(i + 1),
      ];
    } else {
      state = [...state, CartItem(productId: productId, quantity: quantity)];
    }
    _saveCart();
  }

  void setQuantity(int productId, int quantity) {
    if (quantity <= 0) {
      remove(productId);
      return;
    }
    final i = state.indexWhere((e) => e.productId == productId);
    if (i >= 0) {
      state = [
        ...state.sublist(0, i),
        state[i].copyWith(quantity: quantity),
        ...state.sublist(i + 1),
      ];
      _saveCart();
    }
  }

  void remove(int productId) {
    state = state.where((e) => e.productId != productId).toList();
    _saveCart();
  }

  void clear() {
    state = [];
    _saveCart();
  }

  /// Re-fetch cart items from remote (WooCommerce Store API) and update local state.
  Future<void> refreshFromRemote() async {

    try {
      final remote = await StoreCartApiService.instance.fetchFullCart();
      if (!remote.success || remote.data == null) return;
      final remoteItems = cartItemsFromStoreCartJson(remote.data!);
      await StoreCartApiService.instance
          .absorbCartSessionFromCartJson(remote.data!);
      state = remoteItems;
      await _saveCart();
    } catch (_) {
      // Keep local state as-is
    }
  }

  Future<void> applyStoreCartFromJson(Map<String, dynamic> json) async {
    final remoteItems = cartItemsFromStoreCartJson(json);
    state = remoteItems;
    await _saveCart();
  }

  /// After JWT login / registration: push local lines to Store API; on failure clear local cache.
  Future<void> syncLocalCartToStoreAfterLogin() async {

    if (state.isEmpty) {
      // Login can race with auth-listener migration; recover lines from guest key once.
      final prefs = await SharedPreferences.getInstance();
      final userKey = _storageKey();
      final guestRaw = prefs.getString(_guestKey());
      final userRaw = prefs.getString(userKey);
      final candidate = (userRaw != null && userRaw.isNotEmpty) ? userRaw : guestRaw;
      if (candidate != null && candidate.isNotEmpty) {
        try {
          final list = jsonDecode(candidate) as List<dynamic>;
          final recovered = list
              .map((e) => CartItem(
                    productId: e['productId'] as int,
                    quantity: e['quantity'] as int,
                  ))
              .toList();
          if (recovered.isNotEmpty) {
            state = recovered;
            await _saveCart();
            if (guestRaw != null && guestRaw.isNotEmpty) {
              await prefs.remove(_guestKey());
            }
          }
        } catch (_) {}
      }
    }
    if (state.isEmpty) return;
    try {
      // Sequential addItem calls: 1 request per distinct item, exact quantity.
      // Using the batch endpoint was removed as it caused duplicate/failed adds.
      var anyOk = false;
      for (final item in state) {
        final ok = await StoreCartApiService.instance
            .addItem(item.productId, quantity: item.quantity);
        if (ok) anyOk = true;
      }
      if (anyOk) {
        await refreshFromRemote();
      }
      // Don't clear local state on failure — checkout will re-sync via WebView queue.
    } catch (_) {
      // Keep local state intact on error; WebView queue will handle sync at checkout.
    }
  }
}

final cartProvider =
    StateNotifierProvider<CartNotifier, List<CartItem>>((ref) {
  final n = CartNotifier();
  ref.onDispose(n.dispose);
  return n;
});

/// First load of [cartProvider] from disk (no remote merge on cold start).
final cartHydratedProvider = FutureProvider<void>((ref) async {
  await ref.read(cartProvider.notifier).ensureHydrated();
});

int cartItemCount(List<CartItem> cart) {
  return cart.fold(0, (sum, e) => sum + e.quantity);
}
