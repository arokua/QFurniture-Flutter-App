import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app_router.dart';
import '../data/favorites_provider.dart';
import '../domain/product.dart';
import '../utils/asset_path.dart';
import '../utils/html_utils.dart';
import '../../../main.dart';

class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favoriteIds = ref.watch(favoritesProvider);
    final repo = ref.watch(productRepoProvider);

    if (favoriteIds.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Favorites'), elevation: 0),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.favorite_border, size: 80, color: Colors.grey[400]),
              const SizedBox(height: 16),
              Text(
                'No favorites yet',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.grey[600]),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () => context.go('/home'),
                icon: const Icon(Icons.store),
                label: const Text('Browse products'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Favorites'), elevation: 0),
      body: FutureBuilder<List<Product?>>(
        future: Future.wait(
            favoriteIds.map((id) => repo.getById(id))),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final products =
              snapshot.data!.whereType<Product>().toList();
          if (products.isEmpty) {
            return const Center(child: Text('No products found'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: products.length,
            itemBuilder: (context, index) {
              final product = products[index];
              final isFav = ref.watch(favoritesProvider).contains(product.id);
              return _FavoriteProductTile(
                product: product,
                isFavorite: isFav,
                onToggleFavorite: () =>
                    ref.read(favoritesProvider.notifier).toggle(product.id),
                onTap: () => context.push(AppRoutes.product(product.id)),
              );
            },
          );
        },
      ),
    );
  }
}

class _FavoriteProductTile extends StatelessWidget {
  const _FavoriteProductTile({
    required this.product,
    required this.isFavorite,
    required this.onToggleFavorite,
    required this.onTap,
  });

  final Product product;
  final bool isFavorite;
  final VoidCallback onToggleFavorite;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final imagePath = _imagePath(product);
    final isUrl = isImageUrl(product.primaryImage);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
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
                          product.primaryImage,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              Icon(Icons.image_not_supported,
                                  color: Colors.grey[400]),
                        )
                      : Image.asset(
                          assetKeyForImage(imagePath),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              Icon(Icons.image_not_supported,
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
                      decodeHtmlEntities(product.name),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${product.currency} ${product.price.toStringAsFixed(2)}',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  isFavorite ? Icons.favorite : Icons.favorite_border,
                  color: isFavorite ? Colors.red : null,
                ),
                onPressed: onToggleFavorite,
              ),
            ],
          ),
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
