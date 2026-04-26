import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';

import '../../../app_router.dart';
import '../utils/asset_path.dart';
import '../utils/html_utils.dart';
import '../../../providers.dart';
import '../../../config/store_cart_api_service.dart';
import '../../../config/store_config.dart';
import '../../../services/auth_service.dart';
import 'store_webview_screen.dart';
import '../../cart/data/cart_provider.dart';
import '../../cart/data/woo_cart_provider.dart';
import '../domain/product.dart';
import '../domain/product_pricing_policy.dart';
import '../../../utils/user_facing_errors.dart';

class ProductDetailScreen extends ConsumerStatefulWidget {
  final int productId;
  const ProductDetailScreen({super.key, required this.productId});

  @override
  ConsumerState<ProductDetailScreen> createState() =>
      _ProductDetailScreenState();
}

class _ProductDetailScreenState extends ConsumerState<ProductDetailScreen> {
  int _selectedImageIndex = 0;
  bool _isAdding = false;
  final PageController _pageController = PageController();
  bool _descriptionExpanded = false;
  bool _categoriesExpanded = false;
  late Future<Product?> _productFuture;

  @override
  void initState() {
    super.initState();
    // Cache the future so setState (from gallery swipes) doesn't recreate it
    _productFuture = ref.read(productRepoProvider).getById(widget.productId);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Product?>(
      future: _productFuture,
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          debugPrint('ProductDetail error: ${snap.error}');
          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  userFacingCatalogError(snap.error),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }
        // The local data is already fast but might be stale. We render it immediately.
        // We also kick off a silent background update if needed (Fetch-on-Demand Sync).
        final p = snap.data;
        if (p == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Product not found')),
          );
        }

        // Silent background sync removed for stability. 
        // ProductRepository.getById already does the remote fetch.
        
        final decodedName = decodeHtmlEntities(p.name);
        return ListenableBuilder(
          listenable: AuthService.instance,
          builder: (context, _) {
            return Scaffold(
              body: SafeArea(
                top: false,
                bottom: true,
                left: false,
                right: false,
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: 420,
                        child: _buildImageGallery(p),
                      ),
                    ),
                    SliverAppBar(
                      pinned: true,
                      title: Text(
                        decodedName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          shadows: [
                            Shadow(color: Colors.black54, blurRadius: 4),
                          ],
                        ),
                      ),
                      backgroundColor:
                          Theme.of(context).colorScheme.primaryContainer,
                    ),
                    SliverToBoxAdapter(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final isSmall = constraints.maxWidth < 600;
                          final mainContent = _buildDetailMainContent(context, p);
                          final sidebar = _buildDetailSidebar(context, p);
                          if (!isSmall && constraints.maxWidth > 750) {
                            return Padding(
                              padding: const EdgeInsets.all(20.0),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(flex: 3, child: mainContent),
                                  const SizedBox(width: 32),
                                  SizedBox(width: 300, child: sidebar),
                                ],
                              ),
                            );
                          }
                          return Padding(
                            padding: const EdgeInsets.all(20.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                mainContent,
                                const SizedBox(height: 32),
                                sidebar
                              ],
                            ),
                          );
                        },
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

  Widget _buildDetailMainContent(BuildContext context, dynamic p) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: AuthService.instance,
      builder: (context, _) {
        final role = AuthService.instance.currentSession?.role;
        final priceHidden = skuRequiresLoginToViewPrice(p.sku) &&
            !AuthService.instance.isSignedIn;
        return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title (decoded so &amp; etc. display correctly)
        Text(
          decodeHtmlEntities(p.name),
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        // Price
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(child: _buildDetailPrice(context, theme, p, role)),
          ],
        ),
        const SizedBox(height: 16),
        if (p.category.isNotEmpty || p.sku != null) ...[
          _buildProductMetaChips(context, p),
          const SizedBox(height: 16),
        ],
        if (p.description.isNotEmpty) ...[
          Text(
            'Description',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          _buildDescriptionWithReadMore(context, p.description),
          const SizedBox(height: 24),
        ],
        if (p.variants.isNotEmpty) ...[
          Text(
            'Available Variants',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: p.variants.map((v) {
              return Card(
                elevation: v.inStock ? 2 : 0,
                color: v.inStock ? null : Colors.grey[200],
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        v.label,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: v.inStock ? null : Colors.grey[600],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${p.currency} ${v.priceForRole(role).toStringAsFixed(2)}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: v.inStock
                              ? theme.colorScheme.primary
                              : Colors.grey[600],
                        ),
                      ),
                      if (!v.inStock)
                        Text(
                          'Out of Stock',
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.grey[600],
                          ),
                        ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 24),
        ],
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (priceHidden && p.inStock)
              SizedBox(
                height: 50,
                child: FilledButton.icon(
                  onPressed: () => context.push(AppRoutes.login),
                  icon: const Icon(Icons.login, size: 22),
                  label: const Text('Sign in to view price'),
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              )
            else
              SizedBox(
                height: 50,
                child: FilledButton.icon(
                  onPressed: (p.inStock && !_isAdding)
                      ? () async {
                          setState(() => _isAdding = true);
                          try {
                            ref
                                .read(cartProvider.notifier)
                                .add(p.id, quantity: 1);
                            var remoteOk = true;
                            remoteOk = await StoreCartApiService.instance
                                .addItem(p.id, quantity: 1);
                            if (!context.mounted) return;
                            if (remoteOk) ref.invalidate(wooCartProvider);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  remoteOk
                                      ? 'Added ${decodeHtmlEntities(p.name)} to cart'
                                      : 'Saved in your app cart. Cart will sync to the store when you checkout.',
                                ),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          } finally {
                            if (mounted) setState(() => _isAdding = false);
                          }
                        }
                      : null,
                  icon: _isAdding
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.shopping_cart_outlined, size: 22),
                  label: Text(
                      p.inStock ? (_isAdding ? 'Adding...' : 'Add to cart') : 'Out of Stock'),
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            if (!priceHidden && p.inStock) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () {
                  final url = p.permalink;
                  final raw = url?.trim();
                  final absoluteUrl = (raw != null && raw.isNotEmpty)
                      ? (raw.startsWith('/') ? '${kStoreBaseUrl}$raw' : raw)
                      : storeProductUrl(p.id);
                  StoreWebViewScreen.push(
                    context,
                    absoluteUrl,
                    attemptWebLogin: true,
                  );
                },
                icon: const Icon(Icons.open_in_browser, size: 20),
                label: const Text('Open on store website'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 24),
        _buildProductBenefits(context),
      ],
    );
      },
    );
  }

  /// Product benefits: 12 months warranty, Ship in 24 hours, Eco-Friendly Timber. No returns.
  Widget _buildProductBenefits(BuildContext context) {
    const green = Color(0xFF2E7D32);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _benefitItem(context, Icons.shield_outlined, '12 months replacement\nwarranty', green),
          _benefitItem(context, Icons.local_shipping_outlined, 'Ship in 24 hours', green),
          _benefitItem(context, Icons.eco_outlined, 'Eco-Friendly Timber', green),
        ],
      ),
    );
  }

  Widget _buildProductMetaChips(BuildContext context, Product p) {
    final decodedCategories = (p.categoryList.isNotEmpty
            ? p.categoryList
            : p.category
                .split(',')
                .map((category) => category.trim())
                .where((category) => category.isNotEmpty)
                .toList())
        .map(decodeHtmlEntities)
        .toList();
    const defaultVisibleCount = 3;
    final canExpand = decodedCategories.length > defaultVisibleCount;
    final visibleCategories = (_categoriesExpanded || !canExpand)
        ? decodedCategories
        : decodedCategories.take(defaultVisibleCount).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (decodedCategories.isNotEmpty) ...[
          Text(
            'Categories',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final category in visibleCategories)
                Chip(
                  avatar: const Icon(Icons.category, size: 18),
                  label: Text(category),
                ),
              if (canExpand)
                ActionChip(
                  avatar: Icon(
                    _categoriesExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                  ),
                  label: Text(
                    _categoriesExpanded
                        ? 'Show fewer'
                        : 'Show all (${decodedCategories.length})',
                  ),
                  onPressed: () => setState(
                    () => _categoriesExpanded = !_categoriesExpanded,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (p.sku != null)
              Chip(
                avatar: const Icon(Icons.qr_code, size: 18),
                label: Text('SKU: ${p.sku}'),
              ),
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: p.inStock ? Colors.green.shade50 : Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: p.inStock ? Colors.green.shade200 : Colors.red.shade200,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    p.inStock ? Icons.check_circle_outline : Icons.error_outline,
                    size: 16,
                    color: p.inStock ? Colors.green.shade700 : Colors.red.shade700,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    p.stockAmount ?? (p.inStock ? 'In Stock' : 'Out of Stock'),
                    style: TextStyle(
                      color: p.inStock ? Colors.green.shade700 : Colors.red.shade700,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _benefitItem(BuildContext context, IconData icon, String text, Color iconColor) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: iconColor, size: 32),
          const SizedBox(height: 8),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade800,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailPrice(
      BuildContext context, ThemeData theme, Product p, String? role) {
    final priceHidden = skuRequiresLoginToViewPrice(p.sku) &&
        !AuthService.instance.isSignedIn;
    if (priceHidden) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.25),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline, color: theme.colorScheme.primary, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Prices for partner (P-series) products are shown after you sign in.',
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: () => context.push(AppRoutes.login),
              icon: const Icon(Icons.login, size: 20),
              label: const Text('Sign in to view pricing'),
            ),
          ],
        ),
      );
    }
    final sale = p.displaySalePriceForRole(role);
    final reg = p.displayRegularPriceForRole(role);
    if (p.onSale &&
        sale != null &&
        reg != null &&
        reg > 0) {
      final pct =
          ((reg - sale) / reg * 100).round();
      return Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          Text(
            '${p.currency} ${sale.toStringAsFixed(2)}',
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
          Text(
            '${p.currency} ${reg.toStringAsFixed(2)}',
            style: theme.textTheme.titleMedium?.copyWith(
              color: Colors.grey[600],
              decoration: TextDecoration.lineThrough,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.error,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              pct > 0 ? '-$pct%' : 'Sale',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      );
    }
    return Text(
      '${p.currency} ${p.displayCurrentPriceForRole(role).toStringAsFixed(2)}',
      style: theme.textTheme.headlineMedium?.copyWith(
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.primary,
      ),
    );
  }

  Widget _buildDetailSidebar(BuildContext context, Product p) {
    final theme = Theme.of(context);
    final hasMaterial = p.material != null && p.material!.isNotEmpty;
    final rawFinish = p.finish?.trim();
    final forceChemicalFreeFinish = _shouldShowChemicalFreeFinish(p);
    final effectiveFinish =
        forceChemicalFreeFinish ? 'Chemical-free finish' : rawFinish;
    final showSpecs = p.age.isNotEmpty ||
        hasMaterial ||
        (effectiveFinish != null && effectiveFinish.isNotEmpty);
    final rawPermalink = p.permalink?.trim();
    final permalink = (rawPermalink != null && rawPermalink.isNotEmpty)
        ? (rawPermalink.startsWith('/')
            ? '${kStoreBaseUrl}$rawPermalink'
            : rawPermalink)
        : storeProductUrl(p.id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showSpecs) ...[
          Text(
            'Specifications',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          if (p.age.isNotEmpty)
            _detailSpecRow(theme, 'Recommended age', p.age),
          if (hasMaterial)
            _detailSpecRow(theme, 'Material', p.material!.trim()),
          if (effectiveFinish != null && effectiveFinish.isNotEmpty)
            _detailSpecRow(theme, 'Finish', effectiveFinish),
          const SizedBox(height: 20),
        ],
        _buildEthicalSourcingSection(context, p, effectiveFinish),
        const SizedBox(height: 20),
        Text(
          'Additional Details',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () {
            StoreWebViewScreen.push(
              context,
              permalink,
              attemptWebLogin: AuthService.instance.currentSession != null,
            );
          },
          icon: const Icon(Icons.link, size: 18),
          label: const Text('View full product details on website'),
        ),
      ],
    );
  }

  Widget _detailSpecRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              decodeHtmlEntities(value),
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEthicalSourcingSection(
    BuildContext context,
    Product p,
    String? effectiveFinish,
  ) {
    final theme = Theme.of(context);
    final materialText = (p.material != null && p.material!.trim().isNotEmpty)
        ? p.material!.trim()
        : 'Plantation hardwood and sustainably sourced timber';
    final finishText = (effectiveFinish != null && effectiveFinish.isNotEmpty)
        ? effectiveFinish
        : 'Non-toxic, child-safe water-based coating';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFE7F2EE),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Ethical Sourcing & QSAFE Guarantee',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: const Color(0xFF0E5B4C),
            ),
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final isCompact = constraints.maxWidth < 560;
              final left = _buildEthicalInfoColumn(
                context,
                titleA: 'Materials',
                bodyA:
                    '$materialText. We prioritise responsible sourcing and minimal environmental impact.',
                titleB: 'Finish',
                bodyB:
                    '$finishText. Our finishes are selected for safe daily use and tactile comfort for children.',
              );
              final right = _buildEthicalInfoColumn(
                context,
                titleA: 'Safety (QSAFE)',
                bodyA:
                    'Every Qtoys item is tested to meet or exceed relevant Australian and international safety standards.',
              );
              if (isCompact) {
                return Column(
                  children: [
                    left,
                    const SizedBox(height: 12),
                    right,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: left),
                  const SizedBox(width: 16),
                  Expanded(child: right),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildEthicalInfoColumn(
    BuildContext context, {
    required String titleA,
    required String bodyA,
    String? titleB,
    String? bodyB,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$titleA:',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          bodyA,
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
        ),
        if (titleB != null && bodyB != null) ...[
          const SizedBox(height: 12),
          Text(
            '$titleB:',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            bodyB,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
        ],
      ],
    );
  }

  bool _shouldShowChemicalFreeFinish(Product p) {
    final age = p.age.toLowerCase();
    if (age.contains('0-1') || age.contains('0 to 1')) {
      return true;
    }
    final categories = (p.categoryList.isNotEmpty
            ? p.categoryList
            : p.category
                .split(',')
                .map((category) => category.trim())
                .where((category) => category.isNotEmpty))
        .map((category) => category.toLowerCase())
        .toList();
    return categories.any(
      (category) =>
          category.contains('baby deluxe range') ||
          category.contains('baby deluxe'),
    );
  }

  String _detailImagePathAt(dynamic product, int index) {
    if (product.images.isNotEmpty && index < product.images.length) {
      final fromJson = product.images[index];
      if (isImageUrl(fromJson)) return fromJson;
      return normalizeAssetPath(fromJson);
    }
    
    // Fallback if images array is empty or out of bounds
    if (isImageUrl(product.image)) return product.image;
    return normalizeAssetPath(product.image);
  }

  Widget _buildImageGallery(product) {
    final count = product.images.isNotEmpty ? product.images.length : 1;

    // Always use PageView so images are slidable (even with 1 image for consistency)
    return Stack(
      fit: StackFit.expand,
      children: [
        PageView.builder(
          controller: _pageController,
          physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics()),
          itemCount: count,
          onPageChanged: (index) {
            setState(() => _selectedImageIndex = index);
          },
          itemBuilder: (context, index) {
            final imagePath = _detailImagePathAt(product, index);
            final useNetwork = isImageUrl(imagePath);
            return Stack(
              fit: StackFit.expand,
              children: [
                useNetwork
                    ? CachedNetworkImage(
                        imageUrl: imagePath,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Container(
                          color: Colors.grey[200],
                          child: const Center(
                              child: CircularProgressIndicator()),
                        ),
                        errorWidget: (context, url, error) =>
                            _buildImagePlaceholder(),
                      )
                    : Image.asset(
                        assetKeyForImage(imagePath),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _buildImagePlaceholder(),
                      ),
                if (index == 0 &&
                    product.onSale &&
                    product.regularPrice != null &&
                    product.regularPrice! > 0 &&
                    product.salePrice != null &&
                    !(skuRequiresLoginToViewPrice(product.sku) &&
                        !AuthService.instance.isSignedIn))
                  Positioned(
                    top: 16,
                    left: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.error,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _detailDiscountPercent(product),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withOpacity(0.3),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        // Page indicators
        _ImageGalleryIndicator(
          count: count,
          currentIndex: _selectedImageIndex,
          onTap: (index) {
            _pageController.animateToPage(
              index,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
            );
          },
        ),
      ],
    );
  }

  String _detailDiscountPercent(dynamic product) {
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

  static const int _descriptionPreviewLines = 4;

  String _descriptionToPlain(String htmlText) {
    if (htmlText.trim().isEmpty) return '';
    String s = htmlText
        .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    s = s
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'[ \t]+'), ' ');
    return decodeHtmlEntities(s).trim();
  }

  Widget _buildDescriptionWithReadMore(BuildContext context, String htmlText) {
    final plain = _descriptionToPlain(htmlText);
    if (plain.isEmpty) return const SizedBox.shrink();
    final style = Theme.of(context).textTheme.bodyLarge;
    final needsExpand = plain.contains('\n') || plain.length > 280;
    if (!needsExpand) {
      return Text(plain, style: style);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedCrossFade(
          firstChild: Text(
            plain,
            style: style,
            maxLines: _descriptionPreviewLines,
            overflow: TextOverflow.ellipsis,
          ),
          secondChild: Text(plain, style: style),
          crossFadeState: _descriptionExpanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => setState(() => _descriptionExpanded = !_descriptionExpanded),
          icon: Icon(
            _descriptionExpanded ? Icons.expand_less : Icons.expand_more,
            size: 20,
          ),
          label: Text(_descriptionExpanded ? 'Read less' : 'Read more'),
        ),
      ],
    );
  }

  Widget _buildImagePlaceholder() {
    return Container(
      color: Colors.grey[200],
      child: const Center(
        child: Icon(Icons.image_not_supported, size: 64, color: Colors.grey),
      ),
    );
  }
}

class _ImageGalleryIndicator extends StatelessWidget {
  final int count;
  final int currentIndex;
  final void Function(int) onTap;

  const _ImageGalleryIndicator({
    required this.count,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (count <= 1) return const SizedBox.shrink();
    return Positioned(
      bottom: 16,
      left: 0,
      right: 0,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(
          count,
          (index) => GestureDetector(
            onTap: () => onTap(index),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 8.0),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: currentIndex == index ? 24 : 8,
                height: 8,
                decoration: BoxDecoration(
                  color: currentIndex == index
                      ? Colors.white
                      : Colors.white.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
