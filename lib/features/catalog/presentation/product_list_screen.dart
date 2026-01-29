import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../../../app_router.dart';
import '../../cart/data/cart_provider.dart';
import '../data/favorites_provider.dart';
import '../domain/product.dart';
import '../utils/asset_path.dart';
import '../utils/html_utils.dart';
import '../../../main.dart';

final searchQueryProvider = StateProvider<String>((ref) => '');
final selectedCategoryProvider = StateProvider<String?>((ref) => null);
final viewModeProvider =
    StateProvider<bool>((ref) => true); // true = grid, false = list

/// Sort: name_asc, name_desc, price_asc, price_desc
final sortOrderProvider = StateProvider<String>((ref) => 'name_asc');

/// Increment to force product list refresh (pull-to-refresh).
final refreshTriggerProvider = StateProvider<int>((ref) => 0);

class ProductListScreen extends ConsumerStatefulWidget {
  const ProductListScreen({super.key});

  @override
  ConsumerState<ProductListScreen> createState() => _ProductListScreenState();
}

class _ProductListScreenState extends ConsumerState<ProductListScreen> {
  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(productRepoProvider);
    final searchQuery = ref.watch(searchQueryProvider);
    final selectedCategory = ref.watch(selectedCategoryProvider);
    final isGridView = ref.watch(viewModeProvider);

    final cart = ref.watch(cartProvider);
    final cartCount = cartItemCount(cart);
    final sortOrder = ref.watch(sortOrderProvider);
    final refreshTrigger = ref.watch(refreshTriggerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('QFurniture'),
        elevation: 0,
        actions: [
          IconButton(
            icon: Badge(
              isLabelVisible: cartCount > 0,
              label: Text('$cartCount'),
              child: const Icon(Icons.shopping_cart_outlined),
            ),
            onPressed: () => context.push(AppRoutes.cart),
            tooltip: 'Cart',
          ),
          IconButton(
            icon: Icon(isGridView ? Icons.view_list : Icons.grid_view),
            onPressed: () =>
                ref.read(viewModeProvider.notifier).state = !isGridView,
            tooltip: isGridView ? 'List View' : 'Grid View',
          ),
        ],
      ),
      body: Column(
        children: [
          // Search and Filter Bar
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                // Search Bar
                TextField(
                  decoration: InputDecoration(
                    hintText: 'Search products...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () => ref
                                .read(searchQueryProvider.notifier)
                                .state = '',
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surface,
                  ),
                  onChanged: (value) =>
                      ref.read(searchQueryProvider.notifier).state = value,
                ),
                const SizedBox(height: 12),
                // Category Filter: all categories that appear in any product
                FutureBuilder<List<String>>(
                  future: repo.getAll().then((products) {
                    final allCats = products
                        .expand((p) => p.categoryList)
                        .map((c) => c.trim())
                        .where((c) => c.isNotEmpty)
                        .toSet()
                        .toList();
                    allCats.sort();
                    return allCats;
                  }),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData || snapshot.data!.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    final categories = ['All', ...snapshot.data!];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: 40,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: categories.length,
                            itemBuilder: (context, index) {
                              final category = categories[index];
                              final isSelected = selectedCategory == null
                                  ? category == 'All'
                                  : selectedCategory == category;
                              return Padding(
                                padding: const EdgeInsets.only(right: 8.0),
                                child: FilterChip(
                                  label: Text(decodeHtmlEntities(category)),
                                  selected: isSelected,
                                  onSelected: (selected) {
                                    ref
                                            .read(selectedCategoryProvider.notifier)
                                            .state =
                                        category == 'All' ? null : category;
                                  },
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Text(
                              'Sort:',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(width: 8),
                            DropdownButton<String>(
                              value: sortOrder,
                              isDense: true,
                              items: const [
                                DropdownMenuItem(
                                    value: 'name_asc', child: Text('Name A–Z')),
                                DropdownMenuItem(
                                    value: 'name_desc', child: Text('Name Z–A')),
                                DropdownMenuItem(
                                    value: 'price_asc',
                                    child: Text('Price: low to high')),
                                DropdownMenuItem(
                                    value: 'price_desc',
                                    child: Text('Price: high to low')),
                              ],
                              onChanged: (v) {
                                if (v != null) {
                                  ref.read(sortOrderProvider.notifier).state = v;
                                }
                              },
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          // Products List
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                ref.read(refreshTriggerProvider.notifier).state++;
              },
              child: FutureBuilder<List<Product>>(
                future: Future.wait([
                  Future.value(refreshTrigger),
                  repo.getAll(),
                ]).then((r) => r[1] as List<Product>),
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return _buildLoadingGrid(isGridView);
                }
                final allProducts = snap.data ?? [];

                // Apply filters
                var filteredProducts = allProducts;
                if (searchQuery.isNotEmpty) {
                  filteredProducts = filteredProducts
                      .where((p) =>
                          p.name
                              .toLowerCase()
                              .contains(searchQuery.toLowerCase()) ||
                          p.description
                              .toLowerCase()
                              .contains(searchQuery.toLowerCase()) ||
                          (p.sku
                                  ?.toLowerCase()
                                  .contains(searchQuery.toLowerCase()) ??
                              false))
                      .toList();
                }
                if (selectedCategory != null) {
                  final selected = selectedCategory.trim().toLowerCase();
                  filteredProducts = filteredProducts
                      .where((p) {
                        final matchList = p.categoryList
                            .any((c) => c.trim().toLowerCase() == selected);
                        if (matchList) return true;
                        return p.category
                            .toLowerCase()
                            .contains(selected);
                      })
                      .toList();
                }

                if (filteredProducts.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.search_off,
                            size: 64, color: Colors.grey[400]),
                        const SizedBox(height: 16),
                        Text(
                          'No products found',
                          style:
                              Theme.of(context).textTheme.titleLarge?.copyWith(
                                    color: Colors.grey[600],
                                  ),
                        ),
                      ],
                    ),
                  );
                }

                return isGridView
                    ? _buildGridView(filteredProducts)
                    : _buildListView(filteredProducts);
              },
            ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingGrid(bool isGrid) {
    if (isGrid) {
      return GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 0.75,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
        ),
        itemCount: 6,
        itemBuilder: (_, __) => _buildProductCardShimmer(),
      );
    } else {
      return ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: 6,
        itemBuilder: (_, __) => _buildProductListItemShimmer(),
      );
    }
  }

  Widget _buildGridView(List<Product> products) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.75,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: products.length,
      itemBuilder: (context, index) => _buildProductCard(products[index]),
    );
  }

  Widget _buildListView(List<Product> products) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: products.length,
      itemBuilder: (context, index) => _buildProductListItem(products[index]),
    );
  }

  Widget _buildProductCard(Product product) {
    final isFavorite = ref.watch(favoritesProvider).contains(product.id);
    final isUrl = isImageUrl(product.primaryImage);
    final folder = productFolder(product.sku, product.id);
    String imagePath;
    if (isUrl) {
      imagePath = product.primaryImage;
    } else if (product.image.isNotEmpty && !isImageUrl(product.image)) {
      imagePath = normalizeAssetPath(product.image);
    } else {
      final ext = extensionFromPath(product.image.isNotEmpty
          ? product.image
          : product.images.isNotEmpty
              ? product.images.first
              : null);
      imagePath = normalizeAssetPath(
          productMainImagePath(product.sku, product.id, ext: ext));
    }
    debugLogProductImagePath(
      screen: 'ProductListGrid',
      productId: product.id,
      sku: product.sku,
      jsonImage: product.image,
      jsonImagesLength: '${product.images.length}',
      folder: folder,
      pathUsed: imagePath,
      isUrl: isUrl,
    );

    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () => context.push(AppRoutes.product(product.id)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Product Image
            Expanded(
              flex: 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  isUrl
                      ? CachedNetworkImage(
                          imageUrl: product.primaryImage,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Container(
                            color: Colors.grey[200],
                            child: const Center(
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)),
                          ),
                          errorWidget: (context, url, error) =>
                              _buildImagePlaceholder(),
                        )
                      : Image.asset(
                          assetKeyForImage(imagePath),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              _buildImagePlaceholder(),
                        ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(
                            isFavorite ? Icons.favorite : Icons.favorite_border,
                            color: isFavorite ? Colors.red : Colors.white,
                            size: 22,
                          ),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black26,
                            padding: const EdgeInsets.all(4),
                            minimumSize: const Size(32, 32),
                          ),
                          onPressed: () =>
                              ref.read(favoritesProvider.notifier).toggle(product.id),
                        ),
                        if (!product.inStock) ...[
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'Out of Stock',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (product.onSale && product.regularPrice != null &&
                      product.regularPrice! > 0 && product.salePrice != null)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 4),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.error,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _discountPercent(product),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Product Info
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.all(10.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
                    const SizedBox(height: 2),
                    _buildPriceRow(context, product),
                    const SizedBox(height: 4),
                    SizedBox(
                      height: 32,
                      child: FilledButton(
                        onPressed: product.inStock
                            ? () {
                                ref.read(cartProvider.notifier).add(product.id);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                        '${decodeHtmlEntities(product.name)} added to cart'),
                                    action: SnackBarAction(
                                      label: 'Cart',
                                      onPressed: () => context.push(AppRoutes.cart),
                                    ),
                                  ),
                                );
                              }
                            : null,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                        ),
                        child: const Text('Add to cart'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _discountPercent(Product product) {
    if (!product.onSale ||
        product.regularPrice == null ||
        product.regularPrice! <= 0 ||
        product.salePrice == null) return 'Sale';
    final pct = ((product.regularPrice! - product.salePrice!) /
            product.regularPrice! * 100)
        .round();
    return pct > 0 ? '-$pct%' : 'Sale';
  }

  Widget _buildPriceRow(BuildContext context, Product product) {
    final theme = Theme.of(context);
    if (product.onSale &&
        product.regularPrice != null &&
        product.salePrice != null) {
      return Row(
        children: [
          Text(
            '${product.currency} ${product.salePrice!.toStringAsFixed(2)}',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${product.currency} ${product.regularPrice!.toStringAsFixed(2)}',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[600],
              decoration: TextDecoration.lineThrough,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.error,
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              'Sale',
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      );
    }
    return Text(
      '${product.currency} ${product.price.toStringAsFixed(2)}',
      style: TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: 16,
        color: theme.colorScheme.primary,
      ),
    );
  }

  Widget _buildProductListItem(Product product) {
    final isFavorite = ref.watch(favoritesProvider).contains(product.id);
    final isUrl = isImageUrl(product.primaryImage);
    final folder = productFolder(product.sku, product.id);
    String imagePath;
    if (isUrl) {
      imagePath = product.primaryImage;
    } else if (product.image.isNotEmpty && !isImageUrl(product.image)) {
      imagePath = normalizeAssetPath(product.image);
    } else {
      final ext = extensionFromPath(product.image.isNotEmpty
          ? product.image
          : product.images.isNotEmpty
              ? product.images.first
              : null);
      imagePath = normalizeAssetPath(
          productMainImagePath(product.sku, product.id, ext: ext));
    }
    debugLogProductImagePath(
      screen: 'ProductListRow',
      productId: product.id,
      sku: product.sku,
      jsonImage: product.image,
      jsonImagesLength: '${product.images.length}',
      folder: folder,
      pathUsed: imagePath,
      isUrl: isUrl,
    );

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () => context.push(AppRoutes.product(product.id)),
        child: Row(
          children: [
            // Product Image
            SizedBox(
              width: 120,
              height: 120,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  isUrl
                      ? CachedNetworkImage(
                          imageUrl: product.primaryImage,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Container(
                            color: Colors.grey[200],
                            child: const Center(
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)),
                          ),
                          errorWidget: (context, url, error) =>
                              _buildImagePlaceholder(),
                        )
                      : Image.asset(
                          assetKeyForImage(imagePath),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              _buildImagePlaceholder(),
                        ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: IconButton(
                      icon: Icon(
                        isFavorite ? Icons.favorite : Icons.favorite_border,
                        color: isFavorite ? Colors.red : Colors.white,
                        size: 20,
                      ),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black26,
                        padding: const EdgeInsets.all(4),
                        minimumSize: const Size(28, 28),
                      ),
                      onPressed: () =>
                          ref.read(favoritesProvider.notifier).toggle(product.id),
                    ),
                  ),
                  if (!product.inStock)
                    Positioned.fill(
                      child: Container(
                        color: Colors.black.withOpacity(0.3),
                        child: const Center(
                          child: Text(
                            'Out of Stock',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ),
                  if (product.onSale && product.regularPrice != null &&
                      product.regularPrice! > 0 && product.salePrice != null)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 3),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.error,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _discountPercent(product),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Product Info
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      decodeHtmlEntities(product.name),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (product.category.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        decodeHtmlEntities(product.category),
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    _buildPriceRow(context, product),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 32,
                      child: FilledButton(
                        onPressed: product.inStock
                            ? () {
                                ref.read(cartProvider.notifier).add(product.id);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                        '${decodeHtmlEntities(product.name)} added to cart'),
                                    action: SnackBarAction(
                                      label: 'Cart',
                                      onPressed: () => context.push(AppRoutes.cart),
                                    ),
                                  ),
                                );
                              }
                            : null,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                        ),
                        child: const Text('Add to cart'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImagePlaceholder() {
    return Container(
      color: Colors.grey[200],
      child: Icon(Icons.image_not_supported, color: Colors.grey[400], size: 48),
    );
  }

  Widget _buildProductCardShimmer() {
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 3,
            child: Container(color: Colors.grey[300]),
          ),
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                      height: 16,
                      width: double.infinity,
                      color: Colors.grey[300]),
                  const SizedBox(height: 8),
                  Container(height: 14, width: 80, color: Colors.grey[300]),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProductListItemShimmer() {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(width: 120, height: 120, color: Colors.grey[300]),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                      height: 16,
                      width: double.infinity,
                      color: Colors.grey[300]),
                  const SizedBox(height: 8),
                  Container(height: 14, width: 100, color: Colors.grey[300]),
                  const SizedBox(height: 8),
                  Container(height: 18, width: 80, color: Colors.grey[300]),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
