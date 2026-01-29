import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../config/store_link_service.dart';
import '../../catalog/data/product_repository.dart';
import '../../catalog/domain/product.dart';
import '../../catalog/utils/asset_path.dart';
import '../../../app_router.dart';
import '../data/cart_provider.dart';
import '../domain/cart_item.dart';
import '../../../main.dart';

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
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.grey[600]),
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
            onPressed: () {
              ref.read(cartProvider.notifier).clear();
            },
            child: const Text('Clear'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: FutureBuilder<List<Product?>>(
              future: Future.wait(
                  cart.map((e) => repo.getById(e.productId))),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final products = snapshot.data!;
                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: cart.length,
                  itemBuilder: (context, index) {
                    final item = cart[index];
                    final product = index < products.length
                        ? products[index]
                        : null;
                    return _CartListItem(
                      item: item,
                      product: product,
                      onRemove: () =>
                          ref.read(cartProvider.notifier).remove(item.productId),
                      onQuantityChanged: (q) =>
                          ref.read(cartProvider.notifier).setQuantity(item.productId, q),
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
                    ? Image.network(
                        product!.primaryImage,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            Icon(Icons.image_not_supported, color: Colors.grey[400]),
                      )
                    : Image.asset(
                        assetKeyForImage(imagePath),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            Icon(Icons.image_not_supported, color: Colors.grey[400]),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    product!.name,
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
                        onPressed: item.quantity <= 1
                            ? null
                            : () =>
                                onQuantityChanged(item.quantity - 1),
                        icon: const Icon(Icons.remove),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          '${item.quantity}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      IconButton.filledTonal(
                        iconSize: 20,
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        onPressed: () =>
                            onQuantityChanged(item.quantity + 1),
                        icon: const Icon(Icons.add),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
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

  String _imagePath(Product p) {
    if (p.image.isNotEmpty && !isImageUrl(p.image)) {
      return normalizeAssetPath(p.image);
    }
    final ext = extensionFromPath(
        p.image.isNotEmpty ? p.image : (p.images.isNotEmpty ? p.images.first : null));
    return normalizeAssetPath(
        productMainImagePath(p.sku, p.id, ext: ext));
  }
}

class _CartSummary extends ConsumerWidget {
  const _CartSummary({
    required this.cart,
    required this.repo,
  });

  final List<CartItem> cart;
  final ProductRepository repo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<double>(
      future: () async {
        double total = 0;
        for (final item in cart) {
          final p = await repo.getById(item.productId);
          if (p != null) total += p.price * item.quantity;
        }
        return total;
      }(),
      builder: (context, snapshot) {
        final total = snapshot.data ?? 0.0;
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Total (${cartItemCount(cart)} items)',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      'AUD ${total.toStringAsFixed(2)}',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      final ok = await StoreLinkService.openCheckout();
                      if (!context.mounted) return;
                      if (!ok) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                                'Could not open store. Please visit qfurniture.com.au'),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.open_in_browser),
                    label: const Text('Checkout on store (qfurniture.com.au)'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final items = cart
                          .map((e) => (productId: e.productId, quantity: e.quantity))
                          .toList();
                      final ok = await StoreLinkService.openAddCartToStore(items);
                      if (!context.mounted) return;
                      if (!ok) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                                'Could not open store. Add items at qfurniture.com.au'),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.add_shopping_cart),
                    label: const Text('Add cart to store & open cart'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
