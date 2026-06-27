import 'dart:convert';
import 'package:http/http.dart' as http;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../config/store_cart_api_service.dart';
import '../../../app_router.dart';
import '../data/cart_provider.dart';
import '../data/cart_session_refresh.dart';
import '../domain/cart_item.dart';
import '../../catalog/domain/product.dart';
import '../data/store_cart_snapshot.dart';
import '../data/woo_cart_provider.dart';
import '../../../providers.dart';
import '../../../utils/money_format.dart';

import '../../../config/store_config.dart';
import '../../../services/auth_service.dart';
import '../../catalog/presentation/store_webview_screen.dart';
import 'wholesale_checkout_section.dart';


/// DEBUG: raw GET /wp-json/wc/store/v1/cart with all available auth headers.
/// Prints status + body so we can see exactly what the server returns.
final rawStoreCartDebugProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final jwt = AuthService.instance.jwtToken ?? '';
  final cookie = StoreCartApiService.instance.cookie ?? '';
  final cartToken = StoreCartApiService.instance.cartToken ?? '';
  final url = Uri.parse('$kStoreBaseUrl/wp-json/wc/store/v1/cart');

  final headers = <String, String>{
    'Accept': 'application/json',
    'User-Agent': kAppUserAgent,
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
    final isWholesaleCheckout = AuthService.instance.isWholesaleCheckoutRole;
    final isSignedIn = AuthService.instance.isSignedIn;



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
        isWholesale: isWholesaleCheckout,
        error: '$e',
      ),
      data: (woo) {
        final snap = woo.snapshot;
        if (snap == null || snap.isEmpty) {
          return _emptyScaffold(context, ref, isWholesale: isWholesaleCheckout);
        }
        return _loadedScaffold(
          context,
          ref,
          snap: snap,
          isWholesale: isWholesaleCheckout,
        );
      },
    );
  }

  /// Pull-to-refresh and app-bar refresh: re-sync JWT/cookies then fetch live cart.
  static Future<void> _onRefreshCart(WidgetRef ref) async {
    if (AuthService.instance.isSignedIn) {
      await rebootstrapCartSession();
      ref.invalidate(wooCartProvider);
      try {
        await ref.read(wooCartProvider.future);
      } catch (_) {}
      await ref.read(cartProvider.notifier).refreshFromRemote();
      return;
    }
    await ref.read(cartProvider.notifier).refreshFromRemote();
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
          if (!isWholesale)
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
                'Error: $error',
                style: const TextStyle(fontSize: 12, color: Colors.red),
                textAlign: TextAlign.center,
              ),
            ),
          ] else if (!isWholesale && AuthService.instance.isSignedIn) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'The store API returned an empty cart for this app session. '
                'Pull down to refresh, or add items here in the app. '
                'Opening the cart URL in a browser tab is a different session '
                '(you may see null shipping fields or empty items there).',
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
            onPressed: () async {
              ref.read(cartProvider.notifier).clear();
              if (!isWholesale) {
                await StoreCartApiService.instance.clearCart();
                ref.invalidate(wooCartProvider);
              }
            },
            child: const Text('Clear All'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _onRefreshCart(ref),
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                itemCount: snap.lines.length,
              itemBuilder: (context, i) {
                final line = snap.lines[i];
                return _CartLineCard(
                  productId: line.productId,
                  name: line.name,
                  sku: line.sku ?? skuById[line.productId],
                  quantity: line.quantity,
                  unitPriceDisplay: line.formattedUnitPrice,
                  lineTotalDisplay: line.formattedLineTotal,
                  imageUrl: line.imageUrl,
                  onRemove: () async {
                    ref.read(cartProvider.notifier).remove(line.productId);
                    await StoreCartApiService.instance.removeItemByProductId(line.productId);
                    if (context.mounted) ref.invalidate(wooCartProvider);
                  },
                  onQtyChanged: (q) async {
                    if (q <= 0) return;
                    ref.read(cartProvider.notifier).setQuantity(line.productId, q);
                    await StoreCartApiService.instance.updateItemByProductId(line.productId, q);
                    if (context.mounted) ref.invalidate(wooCartProvider);
                  },
                );
              },
            ),
            ),
          ),
          _CartSummary(snapshot: snap, isWholesale: isWholesale),
        ],
      ),
    );
  }

  static void _showDebugSheet(BuildContext context) {
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
  const _GuestCartScaffold({required this.items});

  final List<CartItem> items;

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
        final total = validLines.fold<double>(
          0,
          (sum, line) =>
              sum +
              (line.product!.displayCurrentPriceForRole(null) *
                  line.item.quantity),
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
                    final unit = product.displayCurrentPriceForRole(null);
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
  bool _isUpdating = false;

  Future<void> _handleRemove() async {
    if (_isUpdating) return;
    setState(() => _isUpdating = true);
    try {
      await widget.onRemove();
    } finally {
      if (mounted) setState(() => _isUpdating = false);
    }
  }

  Future<void> _handleQtyChange(int q) async {
    if (_isUpdating) return;
    setState(() => _isUpdating = true);
    try {
      await widget.onQtyChanged(q);
    } finally {
      if (mounted) setState(() => _isUpdating = false);
    }
  }

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

    return Stack(
      children: [
        card,
        if (_isUpdating)
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(12), // Same as typical card border radius
              ),
              child: const Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
              ),
            ),
          ),
      ],
    );
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


class _CartSummary extends ConsumerStatefulWidget {
  const _CartSummary({
    required this.snapshot,
    required this.isWholesale,
  });

  /// Null for wholesale (local-only). Non-null for store users (from wooCartProvider).
  final StoreCartApiSnapshot? snapshot;
  final bool isWholesale;

  @override
  ConsumerState<_CartSummary> createState() => _CartSummaryState();
}

class _CartSummaryState extends ConsumerState<_CartSummary> {
  bool _isSyncing = false;

  Future<void> _handleCheckout(BuildContext context) async {
    if (AuthService.instance.isWholesaleCheckoutRole) return;

    setState(() => _isSyncing = true);
    try {
      final items = widget.snapshot?.lines
              .map((l) => (productId: l.productId, quantity: l.quantity))
              .toList() ??
          <({int productId, int quantity})>[];

      StoreWebViewScreen.push(
        context,
        storeCheckoutUrl,
        attemptWebLogin: AuthService.instance.currentSession != null,
        addToCartItems: items.isEmpty ? null : items,
      );
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isWholesaleCheckout = widget.isWholesale;
    final tv = widget.snapshot?.totalsView;

    // API-driven MOQ: we look at the snapshot.errors
    final moqErrors = widget.snapshot?.errors
            .where((e) => e.contains('must be at least') || e.toLowerCase().contains('minimum'))
            .toList() ??
        [];
    final moqMet = moqErrors.isEmpty;

    double clientTotal = 0;
    if (widget.snapshot != null) {
      for (final l in widget.snapshot!.lines) {
        final minor = l.lineTotalMinor ??
            (l.priceMinor != null ? l.priceMinor! * l.quantity : 0);
        var d = 1.0;
        for (var i = 0; i < l.minorUnit; i++) {
          d *= 10;
        }
        clientTotal += minor / d;
      }
    }

    final useStoreApi = tv != null;
    final titleLeft = useStoreApi ? 'Total' : 'Subtotal';
    final amountRight = useStoreApi && tv.formattedTotal != null
        ? tv.formattedTotal!
        : formatStorePrice(clientTotal);

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
            if (!isWholesaleCheckout) ...[
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (useStoreApi) ...[
                    if (tv!.formattedSubtotal != null &&
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
                  ] else
                    Text(
                      'Shipping: contact warehouse@qtoys.com.au or view at checkout',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    titleLeft,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    amountRight,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ],
            
            // MOQ notice (wholesale only) or API errors
            if (isWholesaleCheckout && !moqMet) ...[
              const SizedBox(height: 12),
              Material(
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
                          moqErrors.join('\n'),
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
            ],
            const SizedBox(height: 12),
            // Checkout note (store only)
            if (!isWholesaleCheckout) ...[
              Text(
                'Checkout happens on the store website. '
                "If you don't see items, tap Add to cart on the store page first.",
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _isSyncing ? null : () => _handleCheckout(context),
                  icon: _isSyncing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.shopping_cart_checkout),
                  label: Text(
                    _isSyncing ? 'Syncing cart...' : 'Checkout on store website',
                  ),
                ),
              ),
            ] else if (widget.snapshot != null) ...[
              WholesaleCheckoutSection(
                snapshot: widget.snapshot!,
                moqMet: moqMet,
              ),
            ],
          ],
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
