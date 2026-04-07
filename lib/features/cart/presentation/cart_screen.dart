import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../../../config/store_cart_api_service.dart';
import '../../catalog/data/product_repository.dart';
import '../../catalog/domain/product.dart';
import '../../catalog/utils/asset_path.dart';
import '../../catalog/utils/html_utils.dart';
import '../../../app_router.dart';
import '../data/cart_provider.dart';
import '../data/store_cart_snapshot.dart';
import '../domain/cart_item.dart';
import '../../../providers.dart';
import '../../../config/store_config.dart';
import '../../../services/auth_service.dart';
import '../../catalog/presentation/store_webview_screen.dart';

/// Cached per cart state — avoids creating a new Future on every build (main-thread churn).
final cartSummaryProductsProvider = FutureProvider<List<Product>>((ref) async {
  final cart = ref.watch(cartProvider);
  final repo = ref.watch(productRepoProvider);
  final products = <Product>[];
  for (final item in cart) {
    final p = await repo.getById(item.productId);
    if (p != null) products.add(p);
  }
  return products;
});

class CartScreen extends ConsumerWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
    final cart = ref.watch(cartProvider);
    final repo = ref.watch(productRepoProvider);

    if (cart.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Cart'), elevation: 0),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.shopping_cart_outlined,
                  size: 80, color: Colors.grey[400]),
              const SizedBox(height: 16),
              Text(
                'Your cart is empty',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(color: Colors.grey[600]),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () => context.go(AppRoutes.home),
                icon: const Icon(Icons.store),
                label: const Text('Browse products'),
              ),
            ],
          ),
        ),
      );
    }

    return ListenableBuilder(
      listenable: AuthService.instance,
      builder: (context, _) {
        final role = AuthService.instance.currentSession?.role;
        final wholesaleLocal = AuthService.instance.isWholesaleCartLocalOnly;
        final cartSnap = ref.watch(storeCartFullProvider);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Cart'),
            elevation: 0,
            actions: [
              TextButton(
                onPressed: () async {
                  ref.read(cartProvider.notifier).clear();
                  if (!wholesaleLocal) {
                    await StoreCartApiService.instance.clearCart();
                  }
                },
                child: const Text('Clear All'),
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: cart.length,
                  itemBuilder: (context, index) {
                    final item = cart[index];
                    return FutureBuilder<Product?>(
                      future: repo.getById(item.productId),
                      builder: (context, snap) {
                        if (snap.connectionState != ConnectionState.done) {
                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: const Padding(
                              padding: EdgeInsets.all(16),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                  SizedBox(width: 12),
                                  Text('Loading...'),
                                ],
                              ),
                            ),
                          );
                        }

                        final product = snap.data;
                        return _CartListItem(
                          item: item,
                          product: product,
                          role: role,
                          apiProductName:
                              cartSnap.asData?.value?.byProductId[item.productId]?.name,
                          onRemove: () {
                            ref
                                .read(cartProvider.notifier)
                                .remove(item.productId);
                            if (!wholesaleLocal) {
                              StoreCartApiService.instance
                                  .removeItemByProductId(item.productId);
                            }
                          },
                          onQuantityChanged: (newQty) {
                            ref.read(cartProvider.notifier).setQuantity(
                                  item.productId,
                                  newQty,
                                );
                            if (!wholesaleLocal) {
                              StoreCartApiService.instance
                                  .updateItemByProductId(
                                      item.productId, newQty);
                            }
                          },
                        );
                      },
                    );
                  },
                ),
              ),
              _CartSummary(cart: cart, repo: repo, cartSnap: cartSnap),
            ],
          ),
        );
      },
    );
  }
}

class _CartListItem extends StatelessWidget {
  const _CartListItem({
    required this.item,
    required this.product,
    required this.role,
    this.apiProductName,
    required this.onRemove,
    required this.onQuantityChanged,
  });

  final CartItem item;
  final Product? product;
  final String? role;
  /// From WooCommerce Store API cart `items[].name` when synced.
  final String? apiProductName;
  final VoidCallback onRemove;
  final void Function(int) onQuantityChanged;

  String _imagePath(Product p) {
    if (isImageUrl(p.primaryImage)) return p.primaryImage;
    if (p.image.isNotEmpty && !isImageUrl(p.image)) {
      return normalizeAssetPath(p.image);
    }
    final ext = extensionFromPath(p.image.isNotEmpty
        ? p.image
        : p.images.isNotEmpty
            ? p.images.first
            : null);
    return normalizeAssetPath(productMainImagePath(p.sku, p.id, ext: ext));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (product == null) {
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: ListTile(
          leading: const Icon(Icons.error_outline),
          title: const Text('Product unavailable'),
          subtitle: Text('ID: ${item.productId}'),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: onRemove,
          ),
        ),
      );
    }

    final imagePath = _imagePath(product!);
    final isUrl = isImageUrl(product!.primaryImage);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 80,
                height: 80,
                child: isUrl
                    ? CachedNetworkImage(
                        imageUrl: product!.primaryImage,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Container(
                          color: Colors.grey[200],
                        ),
                        errorWidget: (context, url, error) => Icon(
                            Icons.image_not_supported,
                            color: Colors.grey[400]),
                      )
                    : Image.asset(
                        assetKeyForImage(imagePath),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Icon(
                            Icons.image_not_supported,
                            color: Colors.grey[400]),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    decodeHtmlEntities(
                      (apiProductName != null && apiProductName!.trim().isNotEmpty)
                          ? apiProductName!
                          : product!.name,
                    ),
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${product!.currency} ${product!.displayCurrentPriceForRole(role).toStringAsFixed(2)}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      IconButton.filledTonal(
                        iconSize: 20,
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        onPressed: () => onQuantityChanged(item.quantity - 1),
                        icon: const Icon(Icons.remove),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          '${item.quantity}',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                      ),
                      IconButton.filledTonal(
                        iconSize: 20,
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        onPressed: () => onQuantityChanged(item.quantity + 1),
                        icon: const Icon(Icons.add),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: Colors.redAccent),
                        onPressed: onRemove,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CartSummary extends ConsumerStatefulWidget {
  const _CartSummary({
    required this.cart,
    required this.repo,
    required this.cartSnap,
  });

  final List<CartItem> cart;
  final ProductRepository repo;
  final AsyncValue<StoreCartApiSnapshot?> cartSnap;

  @override
  ConsumerState<_CartSummary> createState() => _CartSummaryState();
}

class _CartSummaryState extends ConsumerState<_CartSummary> {
  bool _isSyncing = false;

  Future<void> _handleCheckout(BuildContext context) async {
    if (AuthService.instance.isWholesaleCartLocalOnly) {
      final uri = Uri.parse('mailto:sales@qtoys.com.au');
      await launchUrl(uri);
      return;
    }

    setState(() => _isSyncing = true);

    try {
      // Sync the FULL local cart to WooCommerce Store API
      final items = widget.cart
          .map((e) => (productId: e.productId, quantity: e.quantity))
          .toList();
      final success = await StoreCartApiService.instance.syncCartToOnline(items);

      if (!context.mounted) return;

      if (success) {
        // Important: refresh via Store API before opening the WebView.
        // WebView renders cart/checkout using cookie-based sessions; this GET
        // should capture any Set-Cookie so the rendered session cart matches.
        ref.invalidate(storeCartFullProvider);
        await ref.read(cartProvider.notifier).refreshFromRemote();
        if (!context.mounted) return;
        StoreWebViewScreen.push(
          context,
          storeCheckoutUrl,
          attemptWebLogin: true,
          addToCartItems: widget.cart
              .map((e) => (productId: e.productId, quantity: e.quantity))
              .toList(),
        );
      } else {
        // Still refresh local/remote cart state so the WebView opens with
        // the correct server cart when rendering.
        await ref.read(cartProvider.notifier).refreshFromRemote();
        if (!context.mounted) return;
        StoreWebViewScreen.push(
          context,
          storeCheckoutUrl,
          attemptWebLogin: true,
          addToCartItems: widget.cart
              .map((e) => (productId: e.productId, quantity: e.quantity))
              .toList(),
        );
      }
    } catch (_) {
      if (context.mounted) {
        await ref.read(cartProvider.notifier).refreshFromRemote();
        if (!context.mounted) return;
        StoreWebViewScreen.push(
          context,
          storeCheckoutUrl,
          attemptWebLogin: true,
          addToCartItems: widget.cart
              .map((e) => (productId: e.productId, quantity: e.quantity))
              .toList(),
        );
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final asyncProducts = ref.watch(cartSummaryProductsProvider);

    return asyncProducts.when(
      data: (products) {
        final role = AuthService.instance.currentSession?.role;
        final cartTotal = products.fold<double>(0, (total, p) {
          final qty = widget.cart.firstWhere((i) => i.productId == p.id).quantity;
          return total + (p.displayCurrentPriceForRole(role) * qty);
        });
        final currency =
            products.isNotEmpty ? products.first.currency : 'AUD';
        final session = AuthService.instance.currentSession;
        final roleLower = session?.role.toLowerCase() ?? '';
        final isWholesale = roleLower == 'wholesale';
        final snap = widget.cartSnap.asData?.value;
        final tv = snap?.totalsView;
        final useStoreApi =
            snap != null && tv != null && !isWholesale;
        final titleLeft = useStoreApi ? 'Total' : 'Subtotal';
        final amountRight = useStoreApi && tv.formattedTotal != null
            ? tv.formattedTotal!
            : '$currency ${cartTotal.toStringAsFixed(2)}';
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
              children: [
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            titleLeft,
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 4),
                          if (useStoreApi) ...[
                            if (tv.formattedSubtotal != null &&
                                tv.formattedTotal != null &&
                                tv.formattedSubtotal != tv.formattedTotal)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Text(
                                  'Subtotal ${tv.formattedSubtotal}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.65),
                                  ),
                                ),
                              ),
                            Text(
                              tv.shippingLine,
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.65),
                              ),
                            ),
                          ] else
                            Text(
                              'Enter address at checkout for shipping',
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.65),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Text(
                      amountRight,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
                if (isWholesale) ...[
                  const SizedBox(height: 12),
                  Material(
                    color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.local_shipping_outlined,
                              size: 20, color: theme.colorScheme.primary),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Wholesale cart stays in this app only (not synced to the store). '
                              'For shipping costs and to place orders, contact sales@qtoys.com.au.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                if (!isWholesale)
                  Text(
                    'Checkout happens on the store website. '
                    'If you don’t see the items, tap “Add to cart” again on the store page, then complete checkout.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                      height: 1.35,
                    ),
                  ),
                if (!isWholesale) const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _isSyncing
                        ? null
                        : () => _handleCheckout(context),
                    icon: _isSyncing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(isWholesale ? Icons.email_outlined : Icons.shopping_cart_checkout),
                    label: Text(_isSyncing
                        ? 'Syncing cart...'
                        : (isWholesale
                            ? 'Email sales@qtoys.com.au'
                            : 'Checkout on store website')),
                  ),
                ),
              ],
            ),
          ),
        );
      },
      loading: () => Container(
        padding: const EdgeInsets.all(20),
        alignment: Alignment.center,
        child: const SizedBox(
          height: 32,
          width: 32,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (_, __) => Container(
        padding: const EdgeInsets.all(20),
        child: const Text('Could not load totals'),
      ),
    );
  }
}

