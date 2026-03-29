import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../../../config/store_cart_api_service.dart';
import '../../catalog/data/product_repository.dart';
import '../../catalog/domain/product.dart';
import '../../catalog/utils/asset_path.dart';
import '../../catalog/utils/html_utils.dart';
import '../../../app_router.dart';
import '../data/cart_provider.dart';
import '../domain/cart_item.dart';
import '../../../providers.dart';
import '../../../config/store_config.dart';
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cart'),
        elevation: 0,
        actions: [
          TextButton(
            onPressed: () async {
              ref.read(cartProvider.notifier).clear();
              await StoreCartApiService.instance.clearCart();
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
                    final product = snap.data;
                    return _CartListItem(
                      item: item,
                      product: product,
                      onRemove: () {
                        ref.read(cartProvider.notifier).remove(item.productId);
                        StoreCartApiService.instance
                            .removeItemByProductId(item.productId);
                      },
                      onQuantityChanged: (newQty) {
                        ref
                            .read(cartProvider.notifier)
                            .setQuantity(item.productId, newQty);
                        StoreCartApiService.instance
                            .updateItemByProductId(item.productId, newQty);
                      },
                    );
                  },
                );
              },
            ),
          ),
          _CartSummary(cart: cart, repo: repo),
        ],
      ),
    );
  }
}

class _CartListItem extends StatelessWidget {
  const _CartListItem({
    required this.item,
    required this.product,
    required this.onRemove,
    required this.onQuantityChanged,
  });

  final CartItem item;
  final Product? product;
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
                    decodeHtmlEntities(product!.name),
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${product!.currency} ${product!.price.toStringAsFixed(2)}',
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
  });

  final List<CartItem> cart;
  final ProductRepository repo;

  @override
  ConsumerState<_CartSummary> createState() => _CartSummaryState();
}

class _CartSummaryState extends ConsumerState<_CartSummary> {
  bool _isSyncing = false;

  Future<void> _handleCheckout(BuildContext context) async {
    setState(() => _isSyncing = true);

    try {
      // Sync the FULL local cart to WooCommerce Store API
      final items = widget.cart
          .map((e) => (productId: e.productId, quantity: e.quantity))
          .toList();
      final success = await StoreCartApiService.instance.syncCartToOnline(items);

      if (!context.mounted) return;

      if (success) {
        // Open the WooCommerce checkout page
        StoreWebViewScreen.push(context, storeCheckoutUrl);
      } else {
        // Fallback: open store cart page so user can add items manually
        StoreWebViewScreen.push(context, storeCartUrl);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not sync cart. Opening store cart page instead.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (_) {
      if (context.mounted) {
        StoreWebViewScreen.push(context, storeCartUrl);
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
        final cartTotal = products.fold<double>(0, (total, p) {
          final qty = widget.cart.firstWhere((i) => i.productId == p.id).quantity;
          return total + (p.price * qty);
        });
        return Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
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
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Total:',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const Text(
                          'Shipping calculated at checkout',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                    Text(
                      '\$${cartTotal.toStringAsFixed(2)}',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
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
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.shopping_cart_checkout),
                    label: Text(_isSyncing ? 'Syncing cart...' : 'Proceed to checkout'),
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

