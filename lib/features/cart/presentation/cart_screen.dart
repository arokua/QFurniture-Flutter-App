import 'dart:convert';
import 'package:http/http.dart' as http;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../config/store_cart_api_service.dart';
import '../../../app_router.dart';
import '../data/cart_provider.dart';
import '../data/cart_providers.dart';
import '../data/cart_session_refresh.dart';
import '../data/role_adjusted_cart_provider.dart';
import '../domain/cart_item.dart';
import '../domain/role_cart_pricing.dart';
import '../../catalog/domain/product.dart';
import '../data/store_cart_snapshot.dart';
import '../data/woo_cart_provider.dart';
import '../../../providers.dart';
import '../../../utils/money_format.dart';

import '../../../config/local_first_sync_config.dart';
import '../../../config/store_config.dart';
import '../../../services/auth_service.dart';
import '../../../services/cart_cache_service.dart';
import '../../../widgets/local_sync_status_chip.dart';
import '../../orders/data/wholesale_moq_provider.dart';
import 'wholesale_checkout_section.dart';


/// DEBUG: raw GET /wp-json/wc/store/v1/cart with all available auth headers.
/// Prints status + body so we can see exactly what the server returns.
final rawStoreCartDebugProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final jwt = AuthService.instance.jwtToken ?? '';
  final cookie = StoreCartApiService.instance.cookie ?? '';
  final cartToken = StoreCartApiService.instance.cartToken ?? '';
  final url = StoreCartApiService.bustCache(
    Uri.parse('$kStoreBaseUrl/wp-json/wc/store/v1/cart'),
  );

  final headers = <String, String>{
    'Accept': 'application/json',
    'User-Agent': kAppUserAgent,
    'Cache-Control': 'no-cache, no-store, must-revalidate',
    'Pragma': 'no-cache',
  };
  if (jwt.isNotEmpty) headers['Authorization'] = 'Bearer $jwt';
  if (cookie.isNotEmpty) headers['Cookie'] = cookie;
  if (cartToken.isNotEmpty) headers['Cart-Token'] = cartToken;

  try {
    final res = await http.get(url, headers: headers)
        .timeout(const Duration(seconds: 15));
    Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(res.body);
      body = decoded is Map<String, dynamic>
          ? decoded
          : {'_raw': res.body};
    } catch (_) {
      body = {'_raw': res.body};
    }
    return {
      '_status': res.statusCode,
      '_sentJwt': jwt.isNotEmpty,
      '_sentCookie': cookie.isNotEmpty,
      '_sentCartToken': cartToken.isNotEmpty,
      '_responseHeaders': res.headers.toString(),
      ...body,
    };
  } catch (e) {
    return {'_error': e.toString()};
  }
});





class CartScreen extends ConsumerStatefulWidget {
  const CartScreen({super.key});

  @override
  ConsumerState<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends ConsumerState<CartScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (AuthService.instance.isSignedIn) {
        ref.invalidate(wooCartProvider);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final hydrated = ref.watch(cartHydratedProvider);
    return hydrated.when(
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('Cart'), elevation: 0),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (_, __) => const _CartScreenBody(),
      data: (_) => const _CartScreenBody(),
    );
  }
}


class _CartScreenBody extends ConsumerWidget {
  const _CartScreenBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSignedIn = AuthService.instance.isSignedIn;
    final isNativeCheckout =
        kWholesaleNativeCheckoutEnabled && isSignedIn;
    final isWholesaleRole = AuthService.instance.isWholesaleCheckoutRole;



    // Signed-out / guest
    if (!isSignedIn) {
      final localItems = ref.watch(cartProvider);
      if (localItems.isEmpty) {
        return _emptyScaffold(context, ref, isWholesale: false);
      }
      return _GuestCartScaffold(items: localItems);
    }

    // â”€â”€ Authenticated store user: wooCartProvider is the single source of truth
    final wooAsync = ref.watch(wooCartProvider);

    return wooAsync.when(
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('Cart'), elevation: 0),
        body: RefreshIndicator(
          onRefresh: () => _onRefreshCart(ref),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: const [
              SizedBox(height: 120),
              Center(child: CircularProgressIndicator()),
            ],
          ),
        ),
      ),
      error: (e, st) => _emptyScaffold(
        context,
        ref,
        isWholesale: isWholesaleRole,
        error: '$e',
      ),
      data: (woo) {
        final snap = woo.snapshot;
        if (snap == null || snap.isEmpty) {
          if (woo.items.isNotEmpty) {
            return _GuestCartScaffold(
              items: woo.items,
              pricingRole: AuthService.instance.currentSession?.role,
            );
          }
          return _emptyScaffold(context, ref, isWholesale: isWholesaleRole);
        }
        final adjustedAsync = ref.watch(roleAdjustedCartSnapshotProvider);
        return adjustedAsync.when(
          loading: () => _loadedScaffold(
            context,
            ref,
            snap: snap,
            isWholesale: isWholesaleRole,
            isNativeCheckout: isNativeCheckout,
            syncStatus: woo.syncStatus,
            fromCache: woo.fromCache,
            syncError: woo.lastSyncError,
          ),
          error: (_, __) => _loadedScaffold(
            context,
            ref,
            snap: snap,
            isWholesale: isWholesaleRole,
            isNativeCheckout: isNativeCheckout,
            syncStatus: woo.syncStatus,
            fromCache: woo.fromCache,
            syncError: woo.lastSyncError,
          ),
          data: (adjusted) => _loadedScaffold(
            context,
            ref,
            snap: adjusted ?? snap,
            isWholesale: isWholesaleRole,
            isNativeCheckout: isNativeCheckout,
            syncStatus: woo.syncStatus,
            fromCache: woo.fromCache,
            syncError: woo.lastSyncError,
          ),
        );
      },
    );
  }

  /// Pull-to-refresh and app-bar refresh: re-sync JWT/cookies then fetch live cart.
  static Future<void> _onRefreshCart(WidgetRef ref) async {
    if (AuthService.instance.isSignedIn) {
      await rebootstrapCartSession();
    }
    // One reconcile through the coordinator; it pushes the result down its
    // stream, so no provider invalidation is needed.
    await cartCoordinator.reconcile(force: true);
  }

  // â”€â”€ Empty state â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  static Widget _emptyScaffold(
    BuildContext context,
    WidgetRef ref, {
    required bool isWholesale,
    String? error,
  }) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cart'),
        elevation: 0,
        actions: [
          // Diagnostics only: this sheet renders response headers and
          // session-presence flags, which must never reach a production user.
          if (!isWholesale && LocalFirstSyncConfig.diagnosticsEnabled)
            IconButton(
              icon: const Icon(Icons.info_outline),
              tooltip: 'Debug',
              onPressed: () => _showDebugSheet(context),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _onRefreshCart(ref),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
          const SizedBox(height: 60),
          Icon(Icons.shopping_cart_outlined, size: 80, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Center(
            child: Text(
              'Your cart is empty',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: Colors.grey[600]),
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            Center(
              child: Text(
                LocalFirstSyncConfig.diagnosticsEnabled
                    ? 'Error: $error'
                    : "We couldn't refresh your cart just now. "
                        'Pull down to try again.',
                style: TextStyle(
                  fontSize: 12,
                  color: LocalFirstSyncConfig.diagnosticsEnabled
                      ? Colors.red
                      : Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ] else if (!isWholesale && AuthService.instance.isSignedIn) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                LocalFirstSyncConfig.diagnosticsEnabled
                    ? 'The store API returned an empty cart for this app '
                        'session. Pull down to refresh, or add items here in '
                        'the app. Opening the cart URL in a browser tab is a '
                        'different session (you may see null shipping fields '
                        'or empty items there).'
                    : 'Add something you like and it will show up here.',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                textAlign: TextAlign.center,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Center(
            child: FilledButton.icon(
              onPressed: () => context.go(AppRoutes.home),
              icon: const Icon(Icons.store),
              label: const Text('Browse products'),
            ),
          ),
          if (!isWholesale) ...[
            const SizedBox(height: 8),
            Center(
              child: TextButton.icon(
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Refresh cart'),
                onPressed: () => _onRefreshCart(ref),
              ),
            ),
          ],
          const SizedBox(height: 24),
          // const _StoreCartDebugPanel(),
        ],
        ),
      ),
    );
  }



  // â”€â”€ Loaded state with snapshot â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  static Widget _loadedScaffold(
    BuildContext context,
    WidgetRef ref, {
    required StoreCartApiSnapshot snap,
    required bool isWholesale,
    required bool isNativeCheckout,
    CartSyncStatus syncStatus = CartSyncStatus.idle,
    bool fromCache = false,
    String? syncError,
  }) {
    final skuById = ref.watch(catalogSkuByProductIdProvider).valueOrNull ?? const {};
    return Scaffold(
      appBar: AppBar(
        title: Text('Cart (${snap.lines.length} item${snap.lines.length == 1 ? '' : 's'})'),
        elevation: 0,
        actions: [
          // IconButton(
          //   icon: const Icon(Icons.info_outline),
          //   tooltip: 'Debug API response',
          //   onPressed: () => _showDebugSheet(context),
          // ),
          if (!isWholesale)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh cart',
              onPressed: () => _onRefreshCart(ref),
            ),
          TextButton(
            // The coordinator queues one clearAll and drains it; calling the
            // Store API here too would be a second, unordered writer.
            onPressed: () => cartCoordinator.clear(),
            child: const Text('Clear All'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _onRefreshCart(ref),
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: LocalSyncStatusChip.cart(
                      status: syncStatus,
                      fromCache: fromCache,
                      error: syncError,
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    sliver: SliverList.builder(
                      itemCount: snap.lines.length,
                      itemBuilder: (context, i) {
                        final line = snap.lines[i];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _CartLineCard(
                            productId: line.productId,
                            name: line.name,
                            sku: line.sku ?? skuById[line.productId],
                            quantity: line.quantity,
                            unitPriceDisplay: line.formattedUnitPrice,
                            lineTotalDisplay: line.formattedLineTotal,
                            imageUrl: line.imageUrl,
                            // Local-first: the coordinator persists the change,
                            // pushes the new document down its stream and
                            // dispatches in the background. No awaiting the
                            // network, no provider invalidation.
                            onRemove: () =>
                                cartCoordinator.remove(line.productId),
                            onQtyChanged: (q) => q <= 0
                                ? cartCoordinator.remove(line.productId)
                                : cartCoordinator.setQuantity(
                                    line.productId, q),
                          ),
                        );
                      },
                    ),
                  ),
                  if (isWholesale)
                    SliverToBoxAdapter(
                      child: _WholesaleMoqBanner(snapshot: snap),
                    ),
                  const SliverPadding(padding: EdgeInsets.only(bottom: 8)),
                ],
              ),
            ),
          ),
          _CartCheckoutBar(
            snapshot: snap,
            isWholesale: isWholesale,
            isNativeCheckout: isNativeCheckout,
          ),
        ],
      ),
    );
  }

  static void _showDebugSheet(BuildContext context) {
    // Defence in depth: even if a caller forgets the gate, refuse to open.
    if (!LocalFirstSyncConfig.diagnosticsEnabled) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        maxChildSize: 0.92,
        builder: (ctx, ctrl) => SingleChildScrollView(
          controller: ctrl,
          padding: const EdgeInsets.all(16),
          child: const _StoreCartDebugPanel(),
        ),
      ),
    );
  }
}

class _GuestCartScaffold extends ConsumerWidget {
  const _GuestCartScaffold({
    required this.items,
    this.pricingRole,
  });

  final List<CartItem> items;
  final String? pricingRole;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(productRepoProvider);
    final guestLinesFuture = Future.wait(
      items.map((item) async {
        final product = await repo.getById(item.productId);
        return (item: item, product: product);
      }),
    );

    return FutureBuilder<List<({CartItem item, Product? product})>>(
      future: guestLinesFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Scaffold(
            appBar: AppBar(title: const Text('Cart'), elevation: 0),
            body: const Center(child: CircularProgressIndicator()),
          );
        }

        final lines = snapshot.data!;
        final validLines = lines.where((line) => line.product != null).toList();
        final role = pricingRole;
        final total = validLines.fold<double>(
          0,
          (sum, line) =>
              sum +
              (RoleCartPricing.lineTotal(
                line.product!,
                role,
                line.item.quantity,
              )),
        );

        return Scaffold(
          appBar: AppBar(
            title: Text(
                'Cart (${items.length} item${items.length == 1 ? '' : 's'})'),
            elevation: 0,
            actions: [
              TextButton(
                onPressed: () => ref.read(cartProvider.notifier).clear(),
                child: const Text('Clear All'),
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => _CartScreenBody._onRefreshCart(ref),
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    itemCount: lines.length,
                  itemBuilder: (context, index) {
                    final line = lines[index];
                    final item = line.item;
                    final product = line.product;
                    if (product == null) {
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: ListTile(
                          title: Text('Product #${item.productId}'),
                          subtitle: const Text('Unable to load product details'),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline,
                                color: Colors.redAccent),
                            onPressed: () => ref
                                .read(cartProvider.notifier)
                                .remove(item.productId),
                          ),
                        ),
                      );
                    }
                    final unit = RoleCartPricing.unitPrice(product, role);
                    final lineTotal = unit * item.quantity;
                    return _CartLineCard(
                      productId: item.productId,
                      name: product.name,
                      sku: product.sku,
                      quantity: item.quantity,
                      unitPriceDisplay: formatStorePrice(unit),
                      lineTotalDisplay: formatStorePrice(lineTotal),
                      imageUrl: product.primaryImage.startsWith('http')
                          ? product.primaryImage
                          : null,
                      onRemove: () async {
                        ref.read(cartProvider.notifier).remove(item.productId);
                      },
                      onQtyChanged: (q) async {
                        ref.read(cartProvider.notifier).setQuantity(
                              item.productId,
                              q,
                            );
                      },
                    );
                  },
                ),
                ),
              ),
              _GuestCartSummary(
                totalDisplay: formatStorePrice(total),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _GuestCartSummary extends StatelessWidget {
  const _GuestCartSummary({required this.totalDisplay});

  final String totalDisplay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            offset: const Offset(0, -4),
            blurRadius: 10,
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Total',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              totalDisplay,
              textAlign: TextAlign.right,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Sign in on the website to continue checkout, or register as Wholesale / Dropship.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                height: 1.35,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => context.push(AppRoutes.login),
              icon: const Icon(Icons.login),
              label: const Text('Sign in'),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => context.push(AppRoutes.register),
              child: const Text('Register as Wholesale / Dropship'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single cart line rendered directly from API data â€” no product repo lookup.
class _CartLineCard extends StatefulWidget {
  const _CartLineCard({
    required this.productId,
    required this.name,
    this.sku,
    required this.quantity,
    this.unitPriceDisplay,
    this.lineTotalDisplay,
    this.imageUrl,
    required this.onRemove,
    required this.onQtyChanged,
  });

  final int productId;
  final String name;
  final String? sku;
  final int quantity;
  final String? unitPriceDisplay;
  final String? lineTotalDisplay;
  final String? imageUrl;
  final Future<void> Function() onRemove;
  final Future<void> Function(int) onQtyChanged;

  @override
  State<_CartLineCard> createState() => _CartLineCardState();
}

class _CartLineCardState extends State<_CartLineCard> {
  // Deliberately no in-flight gate. The previous `if (_isUpdating) return;`
  // silently swallowed every tap during a two-request round trip, so "+ + +"
  // landed as "+1". The coordinator coalesces a burst into one dispatch, so
  // taps can be accepted unconditionally.

  Future<void> _handleRemove() => widget.onRemove();

  Future<void> _handleQtyChange(int q) => widget.onQtyChanged(q);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final card = Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Product ID / SKU badge
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              clipBehavior: Clip.antiAlias,
              child: widget.imageUrl != null && widget.imageUrl!.isNotEmpty
                  ? Image.network(widget.imageUrl!, fit: BoxFit.cover, width: 56, height: 56)
                  : Text(
                      '#${widget.productId}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                      textAlign: TextAlign.center,
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SKU: ${(widget.sku != null && widget.sku!.isNotEmpty) ? widget.sku! : widget.productId}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[600],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.name,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      // Quantity stepper
                      _QtyButton(
                        icon: Icons.remove,
                        onTap: widget.quantity > 1 ? () => _handleQtyChange(widget.quantity - 1) : null,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Text(
                          '${widget.quantity}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                      ),
                      _QtyButton(
                        icon: Icons.add,
                        onTap: () => _handleQtyChange(widget.quantity + 1),
                      ),
                      const Spacer(),
                      // Price
                      if (widget.lineTotalDisplay != null || widget.unitPriceDisplay != null)
                        Flexible(
                          child: Padding(
                            padding: const EdgeInsets.only(left: 8.0),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: Text(
                                widget.lineTotalDisplay ?? '${widget.unitPriceDisplay ?? ''} x ${widget.quantity}',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              onPressed: _handleRemove,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
      ),
    );

    // No blocking overlay: cart edits are local-first and must never freeze
    // the line while the queue syncs in the background.
    return card;
  }
}

class _QtyButton extends StatelessWidget {
  const _QtyButton({required this.icon, this.onTap});
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey[300]!),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(
          icon,
          size: 16,
          color: onTap == null ? Colors.grey[300] : null,
        ),
      ),
    );
  }
}


class _WholesaleMoqBanner extends ConsumerWidget {
  const _WholesaleMoqBanner({required this.snapshot});

  final StoreCartApiSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final clientTotal = _cartSnapshotTotal(snapshot);
    final moqGate = ref.watch(wholesaleMoqGateProvider).valueOrNull;
    final requiredMoq =
        moqGate?.requiredMoq ?? kWholesaleMinimumFirstOrderAud;
    final moqMet = requiredMoq <= 0 || clientTotal >= requiredMoq;
    if (moqMet) return const SizedBox.shrink();

    final message =
        'Minimum order for wholesale is ${formatStorePrice(requiredMoq)}'
        "${moqGate?.hasCompletedOrder == true ? '' : ' for your first order'}. "
        "You're at ${formatStorePrice(clientTotal)} — add "
        '${formatStorePrice(requiredMoq - clientTotal)} more to proceed.';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Material(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline,
                  size: 20, color: theme.colorScheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    height: 1.35,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

double _cartSnapshotTotal(StoreCartApiSnapshot snap) {
  var total = 0.0;
  for (final l in snap.lines) {
    final minor = l.lineTotalMinor ??
        (l.priceMinor != null ? l.priceMinor! * l.quantity : 0);
    var d = 1.0;
    for (var i = 0; i < l.minorUnit; i++) {
      d *= 10;
    }
    total += minor / d;
  }
  return total;
}

/// Compact sticky footer — native checkout opens in a bottom sheet.
class _CartCheckoutBar extends ConsumerWidget {
  const _CartCheckoutBar({
    required this.snapshot,
    required this.isWholesale,
    required this.isNativeCheckout,
  });

  final StoreCartApiSnapshot snapshot;
  final bool isWholesale;
  final bool isNativeCheckout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tv = snapshot.totalsView;
    final clientTotal = _cartSnapshotTotal(snapshot);

    final moqGate = isWholesale
        ? ref.watch(wholesaleMoqGateProvider).valueOrNull
        : null;
    final requiredMoq = isWholesale
        ? (moqGate?.requiredMoq ?? kWholesaleMinimumFirstOrderAud)
        : 0.0;
    final moqMet =
        !isWholesale || requiredMoq <= 0 || clientTotal >= requiredMoq;

    final amountRight =
        tv.formattedTotal ?? formatStorePrice(clientTotal);

    return Material(
      elevation: 8,
      shadowColor: Colors.black26,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!isWholesale) ...[
                if (tv.formattedSubtotal != null &&
                    tv.formattedTotal != null &&
                    tv.formattedSubtotal != tv.formattedTotal)
                  Text(
                    'Subtotal ${tv.formattedSubtotal}',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                    ),
                  ),
                Text(
                  tv.shippingLine,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                  ),
                ),
                const SizedBox(height: 6),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Total',
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          amountRight,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: isWholesale
                                ? const Color(0xFFC4A035)
                                : theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (isNativeCheckout)
                    FilledButton(
                      onPressed: moqMet
                          ? () => showWholesaleCheckoutSheet(
                                context: context,
                                snapshot: snapshot,
                                moqMet: moqMet,
                              )
                          : null,
                      child: const Text('Place order'),
                    ),
                ],
              ),
              if (isNativeCheckout) ...[
                const SizedBox(height: 8),
                Text(
                  'Tap Payment & proceed for bank details, shipping note, and order submission.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                    height: 1.3,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// â”€â”€ DEBUG: raw /wc/store/v1/cart response â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// Remove this widget once cart sync is confirmed working.
class _StoreCartDebugPanel extends ConsumerWidget {
  const _StoreCartDebugPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(rawStoreCartDebugProvider);
    final theme = Theme.of(context);
    return Card(
      color: Colors.black87,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bug_report, color: Colors.amber, size: 16),
                const SizedBox(width: 6),
                Text('DEBUG â€” GET /wc/store/v1/cart',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: Colors.amber)),
                const Spacer(),
                IconButton(
                  icon:
                      const Icon(Icons.refresh, color: Colors.white70, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Re-fetch',
                  onPressed: () => ref.invalidate(rawStoreCartDebugProvider),
                ),
              ],
            ),
            const Divider(color: Colors.white24, height: 12),
            async.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(8),
                child: Center(
                    child: CircularProgressIndicator(
                        color: Colors.amber, strokeWidth: 2)),
              ),
              error: (e, _) => Text('Error: $e',
                  style: const TextStyle(color: Colors.red, fontSize: 11)),
              data: (map) {
                const encoder = JsonEncoder.withIndent('  ');
                final pretty = encoder.convert(map);
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SelectableText(
                    pretty,
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 10.5,
                      fontFamily: 'monospace',
                      height: 1.4,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
