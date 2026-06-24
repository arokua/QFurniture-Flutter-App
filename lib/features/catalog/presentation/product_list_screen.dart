import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../../../app_router.dart';
import '../../../config/store_cart_api_service.dart';
import '../../cart/data/cart_provider.dart';
import '../../cart/data/woo_cart_provider.dart';
import '../../cart/presentation/widgets/stock_quantity_field.dart';
import '../domain/product.dart';
import '../domain/product_pricing_policy.dart';
import 'category_picker_sheet.dart';
import '../providers/category_providers.dart';
import '../domain/category_filter.dart';
import 'widgets/low_stock_badge.dart';
import 'widgets/product_display_image.dart';
import '../utils/asset_path.dart';
import '../utils/html_utils.dart';
import '../../../providers.dart';
import '../../../services/auth_service.dart';
import '../../../services/product_sync_service.dart';
import '../../../utils/user_facing_errors.dart';
import '../domain/product_sku_aliases.dart';

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
  final idStr = p.id.toString();
  if (queryLower == idStr || idStr.contains(queryLower)) return true;
  final aliasId = kProductSkuCodeToId[queryLower];
  if (aliasId != null && aliasId == p.id) return true;
  return false;
}

final searchQueryProvider = StateProvider<String>((ref) => '');
final viewModeProvider =
    StateProvider<bool>((ref) => true); // true = grid, false = list

/// Sort: name_asc, name_desc, price_asc, price_desc, stock_asc, stock_desc
final sortOrderProvider = StateProvider<String>((ref) => 'name_asc');

/// When true, only products with low stock are shown.
final lowStockOnlyProvider = StateProvider<bool>((ref) => false);

/// Increment to force product list refresh (pull-to-refresh).
final refreshTriggerProvider = StateProvider<int>((ref) => 0);

final allProductsProvider = FutureProvider<List<Product>>((ref) async {
  ref.watch(refreshTriggerProvider);
  final sync = ProductSyncService.instance;
  // Only re-read the catalogue on MAJOR transitions (initial batch ready,
  // full catalogue ready). The service intentionally does NOT notify on every
  // page; per-page progress is exposed via syncProgress/syncStatus instead.
  void onSyncUpdate() => ref.invalidateSelf();
  sync.addListener(onSyncUpdate);
  ref.onDispose(() => sync.removeListener(onSyncUpdate));

  final repo = ref.watch(productRepoProvider);
  return repo.getAll();
});

final filteredProductsProvider = Provider<List<Product>>((ref) {
  final allProducts = ref.watch(allProductsProvider).value ?? [];
  final searchQuery = ref.watch(searchQueryProvider);
  final selectedCategory = ref.watch(selectedCategoryProvider);
  final lowStockOnly = ref.watch(lowStockOnlyProvider);
  final categoryIndex = ref.watch(categoryFilterIndexProvider).valueOrNull;

  var filtered = allProducts;

  if (!AuthService.instance.isSignedIn) {
    filtered = guestPreviewProductList(
      filtered,
      ProductSyncService.guestPreviewProductLimit,
    );
  }

  if (searchQuery.isNotEmpty) {
    final query = searchQuery.toLowerCase();
    filtered =
        filtered.where((p) => productMatchesSearchQuery(p, query)).toList();
  }

  if (selectedCategory != null) {
    if (selectedCategory.id > 0 && categoryIndex != null) {
      filtered = filtered
          .where((p) => categoryIndex.productMatches(p, selectedCategory))
          .toList();
    } else {
      filtered = filtered
          .where((p) => _exactCategoryNameMatch(p, selectedCategory.name))
          .toList();
    }
  }

  if (lowStockOnly) {
    filtered = filtered.where((p) => p.isLowStock).toList();
  }

  return filtered;
});

bool _exactCategoryNameMatch(Product p, String categoryName) {
  final norm = normalizeCategoryName(categoryName);
  for (final c in p.categoryList) {
    if (normalizeCategoryName(c) == norm) return true;
  }
  return normalizeCategoryName(p.category) == norm;
}

List<Product> _newestProducts(List<Product> products, int limit) {
  if (products.length <= limit) return products;
  final sorted = List<Product>.from(products);
  sorted.sort((a, b) => b.id.compareTo(a.id));
  return sorted.sublist(0, limit);
}

/// Newest [limit] products for guest catalogue preview.
List<Product> guestPreviewProductList(List<Product> products, int limit) =>
    _newestProducts(products, limit);

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
    _searchController.text = ref.read(searchQueryProvider);
    ProductSyncService.instance.ensureCatalogLoaded().ignore();
    if (!AuthService.instance.isSignedIn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(selectedCategoryProvider.notifier).state = null;
        }
      });
    }
  }

  void _requireSignIn(BuildContext context, {String? message}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message ?? 'Sign in to access the full catalogue.'),
        action: SnackBarAction(
          label: 'Sign in',
          onPressed: () => context.push(AppRoutes.login),
        ),
      ),
    );
    context.push(AppRoutes.login);
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
    final wooAsync = ref.watch(wooCartProvider);
    // Badge should represent how many different products are in the cart.
    // Use the backend source of truth so it matches the Checkout and Cart screens.
    final cartCount = wooAsync.valueOrNull?.snapshot?.lines.length ?? ref.watch(cartProvider).length;
    
    final sortOrder = ref.watch(sortOrderProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.view_week_outlined),
          tooltip: 'Browse categories',
          onPressed: () {
            if (!AuthService.instance.isSignedIn) {
              _requireSignIn(
                context,
                message: 'Sign in to browse categories and the full catalogue.',
              );
              return;
            }
            showCategoryPickerSheet(
              context,
              onSelected: (category) {
                ref.read(selectedCategoryProvider.notifier).state =
                    category == null
                        ? null
                        : SelectedCategory(
                            id: category.id,
                            name: category.name,
                          );
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
            onPressed: () {
              if (!AuthService.instance.isSignedIn) {
                _requireSignIn(context, message: 'Sign in to view your cart.');
                return;
              }
              context.push(AppRoutes.cart);
            },
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
          ListenableBuilder(
            listenable: Listenable.merge([
              AuthService.instance,
              ProductSyncService.instance,
            ]),
            builder: (context, _) => _CatalogStatusStrip(
              signedIn: AuthService.instance.isSignedIn,
            ),
          ),
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
                          'Category: ${decodeHtmlEntities(selectedCategory.name)}',
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
                    FilterChip(
                      label: const Text('Low stock'),
                      avatar: Icon(
                        Icons.circle,
                        size: 10,
                        color: Colors.amber.shade700,
                      ),
                      selected: ref.watch(lowStockOnlyProvider),
                      onSelected: (v) =>
                          ref.read(lowStockOnlyProvider.notifier).state = v,
                      visualDensity: VisualDensity.compact,
                    ),
                    const Spacer(),
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
                        DropdownMenuItem(
                            value: 'stock_asc',
                            child: Text('Stock: low to high')),
                        DropdownMenuItem(
                            value: 'stock_desc',
                            child: Text('Stock: high to low')),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          ref.read(sortOrderProvider.notifier).state = v;
                        }
                      },
                    ),
                  ],
                ),
                if (ref.watch(lowStockOnlyProvider)) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const LowStockBadge(showLabel: true),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Yellow dot = low stock (${kLowStockThreshold} or fewer left)',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: Colors.amber.shade900,
                              ),
                        ),
                      ),
                    ],
                  ),
                ],
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
                    loading: () {
                      final sync = ProductSyncService.instance;
                      if (sync.initialBatchReady) {
                        final partial = ref.watch(filteredProductsProvider);
                        if (partial.isNotEmpty) {
                          return _buildProductResults(
                            context,
                            partial,
                            isGridView,
                            sortOrder,
                          );
                        }
                      }
                      return _buildLoadingState(
                        message: sync.statusMessage,
                      );
                    },
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
                      final sync = ProductSyncService.instance;

                      if (filteredProducts.isEmpty &&
                          sync.isLoadingInitial) {
                        return _buildLoadingState(message: sync.statusMessage);
                      }

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

                      return _buildProductResults(
                        context,
                        filteredProducts,
                        isGridView,
                        sortOrder,
                      );
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

  /// Sort products by [sortOrder] (role-aware price where applicable).
  static List<Product> _sortProducts(
    List<Product> products,
    String sortOrder,
    String? role,
  ) {
    final list = List<Product>.from(products);
    switch (sortOrder) {
      case 'name_asc':
        list.sort((a, b) => a.name.compareTo(b.name));
        break;
      case 'name_desc':
        list.sort((a, b) => b.name.compareTo(a.name));
        break;
      case 'price_asc':
        list.sort((a, b) => a
            .displayCurrentPriceForRole(role)
            .compareTo(b.displayCurrentPriceForRole(role)));
        break;
      case 'price_desc':
        list.sort((a, b) => b
            .displayCurrentPriceForRole(role)
            .compareTo(a.displayCurrentPriceForRole(role)));
        break;
      case 'stock_asc':
        list.sort((a, b) => a.stockSortKey.compareTo(b.stockSortKey));
        break;
      case 'stock_desc':
        list.sort((a, b) => b.stockSortKey.compareTo(a.stockSortKey));
        break;
      default:
        list.sort((a, b) => a.name.compareTo(b.name));
    }
    return list;
  }

  Widget _buildProductResults(
    BuildContext context,
    List<Product> filteredProducts,
    bool isGridView,
    String sortOrder,
  ) {
    return ListenableBuilder(
      listenable: AuthService.instance,
      builder: (context, _) {
        final role = AuthService.instance.currentSession?.role;
        final sorted = _sortProducts(filteredProducts, sortOrder, role);
        return isGridView
            ? _buildGridView(sorted, role)
            : _buildListView(sorted, role);
      },
    );
  }

  Widget _buildLoadingState({String? message}) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 180),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                const SizedBox(height: 18),
                Text(
                  message ?? 'Loading products from the server...',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Please wait a moment. Your catalog will appear shortly.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGridView(List<Product> products, String? role) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.68,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
      ),
      itemCount: products.length,
      itemBuilder: (context, index) =>
          _buildProductCard(products[index], role),
    );
  }

  Widget _buildListView(List<Product> products, String? role) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: products.length,
      itemBuilder: (context, index) =>
          _buildProductListItem(products[index], role),
    );
  }

  Widget _buildProductCard(Product product, String? role) {
    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () => _showQuickView(context, product, ref, role),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ProductDisplayImageLive(
                    product: product,
                    fit: BoxFit.cover,
                    errorWidget: _buildImagePlaceholder(),
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
                  if (product.isLowStock)
                    const Positioned(
                      top: 8,
                      right: 8,
                      child: LowStockBadge(),
                    ),
                  if (!_hidePriceForGuest(product) &&
                      product.onSale &&
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
                          child: _buildPriceRow(context, product, role),
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

  bool _hidePriceForGuest(Product product) =>
      skuRequiresLoginToViewPrice(product.sku) &&
      !AuthService.instance.isSignedIn;

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

  Widget _buildPriceRow(BuildContext context, Product product, String? role) {
    final theme = Theme.of(context);
    if (_hidePriceForGuest(product)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 15, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Sign in to view price',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
                  ),
                ),
              ),
            ],
          ),
          TextButton(
            onPressed: () => context.push(AppRoutes.login),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Sign in'),
          ),
        ],
      );
    }
    final sale = product.displaySalePriceForRole(role);
    final reg = product.displayRegularPriceForRole(role);
    if (product.onSale && sale != null && reg != null) {
      return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${product.currency} ${sale.toStringAsFixed(2)}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${product.currency} ${reg.toStringAsFixed(2)}',
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
      '${product.currency} ${product.displayCurrentPriceForRole(role).toStringAsFixed(2)}',
      style: TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: 15,
        color: theme.colorScheme.primary,
      ),
    );
  }

  Widget _buildProductListItem(Product product, String? role) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () => _showQuickView(context, product, ref, role),
        child: Row(
          children: [
            SizedBox(
              width: 120,
              height: 120,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ProductDisplayImageLive(
                    product: product,
                    fit: BoxFit.cover,
                    errorWidget: _buildImagePlaceholder(),
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
                  if (product.isLowStock)
                    const Positioned(
                      top: 6,
                      right: 6,
                      child: LowStockBadge(),
                    ),
                  if (!_hidePriceForGuest(product) &&
                      product.onSale &&
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
                            child: _buildPriceRow(context, product, role),
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

void _showQuickView(
  BuildContext context,
  Product product,
  WidgetRef ref,
  String? role,
) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _QuickViewModal(product: product, role: role),
  );
}

class _QuickViewModal extends ConsumerStatefulWidget {
  final Product product;
  final String? role;
  const _QuickViewModal({required this.product, required this.role});

  @override
  ConsumerState<_QuickViewModal> createState() => _QuickViewModalState();
}

class _QuickViewModalState extends ConsumerState<_QuickViewModal> {
  int _quantity = 1;
  bool _isAdding = false;

  @override
  void initState() {
    super.initState();
    final cap = widget.product.parsedStockQuantityApprox;
    if (cap != null && cap > 0 && _quantity > cap) {
      _quantity = cap;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = widget.product;

    return ListenableBuilder(
      listenable: AuthService.instance,
      builder: (context, _) {
        final locked = skuRequiresLoginToViewPrice(p.sku) &&
            !AuthService.instance.isSignedIn;
        return _quickViewBody(context, theme, p, locked);
      },
    );
  }

  Widget _quickViewBody(
    BuildContext context,
    ThemeData theme,
    Product p,
    bool priceLocked,
  ) {
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
        bottom: MediaQuery.of(context).padding.bottom +
            MediaQuery.of(context).viewInsets.bottom +
            20,
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
                  child: ProductDisplayImageLive(
                    product: p,
                    fit: BoxFit.cover,
                    errorWidget: const Icon(
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
                    if (priceLocked)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.lock_outline,
                                  size: 18, color: theme.colorScheme.primary),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Partner pricing is available after you sign in.',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                              context.push(AppRoutes.login);
                            },
                            child: const Text('Sign in to view price'),
                          ),
                        ],
                      )
                    else
                      Text(
                        '${p.currency} ${p.displayCurrentPriceForRole(widget.role).toStringAsFixed(2)}',
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
          if (!priceLocked) ...[
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Quantity',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                ),
                p.inStock
                    ? StockQuantityField(
                        quantity: _quantity,
                        stockCeiling: p.parsedStockQuantityApprox,
                        onChanged: (n) => setState(() => _quantity = n),
                      )
                    : Text(
                        'Out of stock',
                        style: TextStyle(
                          color: theme.colorScheme.error,
                          fontWeight: FontWeight.w600,
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
                    onPressed: (p.inStock && !_isAdding)
                        ? () async {
                            setState(() => _isAdding = true);
                            try {
                              ref
                                  .read(cartProvider.notifier)
                                  .add(p.id, quantity: _quantity);
                              var remoteOk = true;
                              remoteOk = await StoreCartApiService.instance
                                  .addItem(p.id, quantity: _quantity);
                              if (!context.mounted) return;
                              if (remoteOk) ref.invalidate(wooCartProvider);
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(remoteOk
                                      ? 'Added $_quantity x ${decodeHtmlEntities(p.name)} to cart'
                                      : 'Added locally. Cart will sync to the store at checkout.'),
                                  duration: const Duration(seconds: 2),
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10)),
                                ),
                              );
                            } finally {
                              if (mounted) setState(() => _isAdding = false);
                            }
                          }
                        : null,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: _isAdding
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.shopping_bag_outlined),
                    label: Text(p.inStock
                        ? (_isAdding ? 'Adding...' : 'Add to Cart')
                        : 'Out of Stock'),
                  ),
                ),
              ],
            ),
          ] else ...[
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () {
                  Navigator.pop(context);
                  context.push(AppRoutes.product(p.id), extra: p);
                },
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('View product details'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Guest preview banner and subtle background-sync indicator for signed-in users.
class _CatalogStatusStrip extends StatelessWidget {
  const _CatalogStatusStrip({required this.signedIn});

  final bool signedIn;

  @override
  Widget build(BuildContext context) {
    final sync = ProductSyncService.instance;
    final theme = Theme.of(context);

    if (!signedIn) {
      return Material(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.lock_outline,
                size: 18,
                color: theme.colorScheme.onSecondaryContainer,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Preview: latest ${ProductSyncService.guestPreviewProductLimit} products. '
                  'Sign in for the full catalogue, categories, and checkout.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => context.push(AppRoutes.login),
                child: const Text('Sign in'),
              ),
            ],
          ),
        ),
      );
    }

    if (!sync.isBackgroundSyncing && sync.fullCatalogReady) {
      return const SizedBox.shrink();
    }

    // Drive the live progress from the lightweight ValueNotifiers so updating
    // the bar never re-runs the (expensive) product-list provider.
    return ValueListenableBuilder<double?>(
      valueListenable: sync.syncProgress,
      builder: (context, progress, _) {
        return ValueListenableBuilder<String?>(
          valueListenable: sync.syncStatus,
          builder: (context, status, __) {
            final total = sync.reportedTotal;
            return Material(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.55),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: progress,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        status ?? 'Syncing catalogue in the background…',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    if (total != null)
                      Text(
                        '${sync.loadedCount}/$total',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
