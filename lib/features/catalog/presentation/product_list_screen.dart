import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../../../app_router.dart';
import '../../../config/store_cart_api_service.dart';
import '../../cart/data/cart_provider.dart';
import '../data/favorites_provider.dart';
import '../domain/product.dart';
import 'category_picker_sheet.dart';
import '../utils/asset_path.dart';
import '../utils/html_utils.dart';
import '../../../providers.dart';
import '../../../services/product_sync_service.dart';
import '../../../utils/user_facing_errors.dart';

/// Search name, SKU, categories, material, color — not full HTML description (avoids jank/OOM).
bool productMatchesSearchQuery(Product p, String queryLower) {
  if (queryLower.isEmpty) return true;
  if (p.name.toLowerCase().contains(queryLower)) return true;
  if (p.sku != null && p.sku!.toLowerCase().contains(queryLower)) return true;
  for (final c in p.categoryList) {
    if (c.toLowerCase().contains(queryLower)) return true;
  }
  if (p.category.isNotEmpty && p.category.toLowerCase().contains(queryLower)) {
    return true;
  }
  final m = p.material;
  if (m != null && m.toLowerCase().contains(queryLower)) return true;
  final col = p.color;
  if (col != null && col.toLowerCase().contains(queryLower)) return true;
  return false;
}

final searchQueryProvider = StateProvider<String>((ref) => '');
final selectedCategoryProvider = StateProvider<String?>((ref) => null);
final viewModeProvider =
    StateProvider<bool>((ref) => true); // true = grid, false = list

/// Sort: name_asc, name_desc, price_asc, price_desc
final sortOrderProvider = StateProvider<String>((ref) => 'name_asc');

/// Increment to force product list refresh (pull-to-refresh).
final refreshTriggerProvider = StateProvider<int>((ref) => 0);

final allProductsProvider = FutureProvider<List<Product>>((ref) async {
  ref.watch(refreshTriggerProvider);
  final repo = ref.watch(productRepoProvider);
  return repo.getAll();
});

final filteredProductsProvider = Provider<List<Product>>((ref) {
  final allProducts = ref.watch(allProductsProvider).value ?? [];
  final searchQuery = ref.watch(searchQueryProvider);
  final selectedCategory = ref.watch(selectedCategoryProvider);
  final sortOrder = ref.watch(sortOrderProvider);

  var filtered = allProducts;

  if (searchQuery.isNotEmpty) {
    final query = searchQuery.toLowerCase();
    filtered =
        filtered.where((p) => productMatchesSearchQuery(p, query)).toList();
  }

  if (selectedCategory != null) {
    final selectedNorm = _ProductListScreenState._normalizeCategoryForMatch(selectedCategory);
    filtered = filtered.where((p) {
      final matchList = p.categoryList.any((c) =>
          _ProductListScreenState._normalizeCategoryForMatch(c) == selectedNorm);
      if (matchList) return true;
      final catNorm = _ProductListScreenState._normalizeCategoryForMatch(p.category);
      return catNorm == selectedNorm;
    }).toList();
  }

  return _ProductListScreenState._sortProducts(filtered, sortOrder);
});

class ProductListScreen extends ConsumerStatefulWidget {
  const ProductListScreen({super.key});

  @override
  ConsumerState<ProductListScreen> createState() => _ProductListScreenState();
}

class _ProductListScreenState extends ConsumerState<ProductListScreen> {
  final _searchController = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    // Sync controller text from provider (in case of hot reload / restore)
    _searchController.text = ref.read(searchQueryProvider);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) {
        ref.read(searchQueryProvider.notifier).state = value;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final searchQuery = ref.watch(searchQueryProvider);
    final selectedCategory = ref.watch(selectedCategoryProvider);
    final isGridView = ref.watch(viewModeProvider);
    final cart = ref.watch(cartProvider);
    final cartCount = cartItemCount(cart);
    final sortOrder = ref.watch(sortOrderProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.category_outlined),
          tooltip: 'Browse categories',
          onPressed: () {
            showCategoryPickerSheet(
              context,
              onSelected: (name) {
                ref.read(selectedCategoryProvider.notifier).state = name;
              },
            );
          },
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary, // Brand Color
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Q',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 22,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'Toys',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        centerTitle: true,
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
                // Search Bar — uses TextEditingController + debounce
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search products...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              ref
                                  .read(searchQueryProvider.notifier)
                                  .state = '';
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surface,
                  ),
                  onChanged: _onSearchChanged,
                ),
                const SizedBox(height: 8),
                if (selectedCategory != null) ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Category: ${decodeHtmlEntities(selectedCategory)}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 22),
                        tooltip: 'Clear category',
                        onPressed: () =>
                            ref.read(selectedCategoryProvider.notifier).state =
                                null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
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
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              children: [
                ref.watch(allProductsProvider).maybeWhen(
                  data: (_) {
                    final count = ref.watch(filteredProductsProvider).length;
                    return Text('$count products found',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.grey.shade600,
                              fontWeight: FontWeight.bold,
                            ));
                  },
                  orElse: () => const SizedBox.shrink(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Products List
          Expanded(
            child: Builder(
              builder: (context) {
                final allProductsAsync = ref.watch(allProductsProvider);

                return RefreshIndicator(
                  onRefresh: () async {
                    await ProductSyncService.instance.forceRefresh();
                    ref.read(refreshTriggerProvider.notifier).state++;
                  },
                  child: allProductsAsync.when(
                    loading: () => _buildLoadingGrid(isGridView),
                    error: (e, st) {
                      debugPrint('allProductsProvider error: $e\n$st');
                      return ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          SizedBox(
                            height: 300,
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  userFacingCatalogError(e),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                    data: (_) {
                      final filteredProducts = ref.watch(filteredProductsProvider);

                      if (filteredProducts.isEmpty) {
                        return ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            SizedBox(
                              height: 300,
                              child: Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.search_off,
                                        size: 64, color: Colors.grey[400]),
                                    const SizedBox(height: 16),
                                    Text(
                                      'No products found',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge
                                          ?.copyWith(
                                            color: Colors.grey[600],
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        );
                      }

                      return isGridView
                          ? _buildGridView(filteredProducts)
                          : _buildListView(filteredProducts);
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Normalize category string for matching (handles "Children's" vs "Childrens", spaces, case).
  static String _normalizeCategoryForMatch(String s) {
    if (s.isEmpty) return '';
    return s
        .trim()
        .toLowerCase()
        .replaceAll("'", '')
        .replaceAll('\u2019', '') // right single quote
        .replaceAll('\u2018', '') // left single quote
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Sort products by [sortOrder]: name_asc, name_desc, price_asc, price_desc (uses current price).
  static List<Product> _sortProducts(List<Product> products, String sortOrder) {
    final list = List<Product>.from(products);
    switch (sortOrder) {
      case 'name_asc':
        list.sort((a, b) => a.name.compareTo(b.name));
        break;
      case 'name_desc':
        list.sort((a, b) => b.name.compareTo(a.name));
        break;
      case 'price_asc':
        list.sort((a, b) => a.price.compareTo(b.price));
        break;
      case 'price_desc':
        list.sort((a, b) => b.price.compareTo(a.price));
        break;
      default:
        list.sort((a, b) => a.name.compareTo(b.name));
    }
    return list;
  }

  Widget _buildLoadingGrid(bool isGrid) {
    if (isGrid) {
      return GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 0.68,
          crossAxisSpacing: 14,
          mainAxisSpacing: 14,
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
        childAspectRatio: 0.68,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
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
        onTap: () => _showQuickView(context, product, ref),
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
                    child: IconButton(
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
                      onPressed: () => ref
                          .read(favoritesProvider.notifier)
                          .toggle(product.id),
                    ),
                  ),
                  if (!product.inStock)
                    Positioned(
                      top: 48,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.9),
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
                    ),
                  if (product.onSale &&
                      product.regularPrice != null &&
                      product.regularPrice! > 0 &&
                      product.salePrice != null)
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
            // Product Info (clip: sale price row must not overflow tight grid cells)
            Expanded(
              flex: 2,
              child: ClipRect(
                child: Padding(
                  padding: const EdgeInsets.all(10.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Text(
                            decodeHtmlEntities(product.name),
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                              height: 1.2,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: _buildPriceRow(context, product),
                        ),
                      ),
                    ],
                  ),
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
            product.regularPrice! *
            100)
        .round();
    return pct > 0 ? '-$pct%' : 'Sale';
  }

  Widget _buildPriceRow(BuildContext context, Product product) {
    final theme = Theme.of(context);
    if (product.onSale &&
        product.regularPrice != null &&
        product.salePrice != null) {
      return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${product.currency} ${product.salePrice!.toStringAsFixed(2)}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${product.currency} ${product.regularPrice!.toStringAsFixed(2)}',
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey[600],
                decoration: TextDecoration.lineThrough,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.error,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'Sale',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Text(
      '${product.currency} ${product.price.toStringAsFixed(2)}',
      style: TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: 15,
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
        onTap: () => _showQuickView(context, product, ref),
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
                      onPressed: () => ref
                          .read(favoritesProvider.notifier)
                          .toggle(product.id),
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
                  if (product.onSale &&
                      product.regularPrice != null &&
                      product.regularPrice! > 0 &&
                      product.salePrice != null)
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
            Expanded(
              child: SizedBox(
                height: 120,
                child: ClipRect(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
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
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        const Spacer(),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: _buildPriceRow(context, product),
                          ),
                        ),
                      ],
                    ),
                  ),
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

void _showQuickView(BuildContext context, Product product, WidgetRef ref) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _QuickViewModal(product: product),
  );
}

class _QuickViewModal extends ConsumerStatefulWidget {
  final Product product;
  const _QuickViewModal({required this.product});

  @override
  ConsumerState<_QuickViewModal> createState() => _QuickViewModalState();
}

class _QuickViewModalState extends ConsumerState<_QuickViewModal> {
  int _quantity = 1;

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
    final p = widget.product;
    final imagePath = _imagePath(p);
    final isUrl = isImageUrl(p.primaryImage);

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 12,
        bottom: MediaQuery.of(context).padding.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 100,
                  height: 100,
                  child: isUrl
                      ? CachedNetworkImage(
                          imageUrl: p.primaryImage,
                          fit: BoxFit.cover,
                          placeholder: (context, url) =>
                              Container(color: Colors.grey[200]),
                          errorWidget: (context, url, error) => const Icon(
                            Icons.image_not_supported,
                            color: Colors.grey,
                          ),
                        )
                      : Image.asset(
                          assetKeyForImage(imagePath),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(
                            Icons.image_not_supported,
                            color: Colors.grey,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      decodeHtmlEntities(p.name),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${p.currency} ${p.price.toStringAsFixed(2)}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (p.stockAmount != null || !p.inStock)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: p.inStock ? Colors.green.shade50 : Colors.red.shade50,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: p.inStock ? Colors.green.shade200 : Colors.red.shade200,
                          ),
                        ),
                        child: Text(
                          p.stockAmount ?? (p.inStock ? 'In Stock' : 'Out of Stock'),
                          style: TextStyle(
                              color: p.inStock ? Colors.green.shade700 : Colors.red.shade700,
                              fontWeight: FontWeight.bold,
                              fontSize: 12),
                        ),
                      )
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Quantity',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
              ),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.remove, size: 20),
                      onPressed: _quantity > 1
                          ? () => setState(() => _quantity--)
                          : null,
                    ),
                    Text(
                      '$_quantity',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add, size: 20),
                      onPressed: p.inStock
                          ? () => setState(() => _quantity++)
                          : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    context.push(
                      AppRoutes.product(p.id),
                      extra: p,
                    );
                  },
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('View Details'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: p.inStock
                      ? () async {
                          ref
                              .read(cartProvider.notifier)
                              .add(p.id, quantity: _quantity);
                          var remoteOk = await StoreCartApiService.instance
                              .addItem(p.id, quantity: _quantity);
                          if (!remoteOk) {
                            final cart = ref.read(cartProvider);
                            remoteOk = await StoreCartApiService.instance
                                .syncCartToOnline(
                              cart
                                  .map((e) => (
                                        productId: e.productId,
                                        quantity: e.quantity,
                                      ))
                                  .toList(),
                            );
                          }
                          if (remoteOk) {
                            await ref
                                .read(cartProvider.notifier)
                                .refreshFromRemote();
                          }
                          if (!context.mounted) return;
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(remoteOk
                                  ? 'Added $_quantity x ${decodeHtmlEntities(p.name)} to cart'
                                  : 'Added locally. Online cart sync failed; try Checkout sync.'),
                              duration: const Duration(seconds: 2),
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                            ),
                          );
                        }
                      : null,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.shopping_bag_outlined),
                  label: const Text('Add to Cart'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
