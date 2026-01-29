import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
// import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
// import '../data/product_repository.dart';
import '../utils/asset_path.dart';
import '../utils/html_utils.dart';
import '../../../main.dart';
import '../../../app_router.dart';
import '../../../config/store_link_service.dart';
import '../../cart/data/cart_provider.dart';
import 'package:go_router/go_router.dart';

class ProductDetailScreen extends ConsumerStatefulWidget {
  final int productId;
  const ProductDetailScreen({super.key, required this.productId});

  @override
  ConsumerState<ProductDetailScreen> createState() =>
      _ProductDetailScreenState();
}

class _ProductDetailScreenState extends ConsumerState<ProductDetailScreen> {
  int _selectedImageIndex = 0;
  final PageController _pageController = PageController();

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(productRepoProvider);
    return FutureBuilder(
      future: repo.getById(widget.productId),
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final p = snap.data;
        if (p == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Product not found')),
          );
        }
        final decodedName = decodeHtmlEntities(p.name);
        return Scaffold(
          body: Column(
            children: [
              // Fixed-height gallery so horizontal swipe works (not stolen by scroll)
              SizedBox(
                height: 400,
                child: _buildImageGallery(p),
              ),
              Expanded(
                child: CustomScrollView(
                  slivers: [
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
                          final useTwoColumns = constraints.maxWidth > 700;
                          final mainContent =
                              _buildDetailMainContent(context, p);
                          final sidebar = _buildDetailSidebar(context, p);
                          if (useTwoColumns) {
                            return Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(flex: 2, child: mainContent),
                                  const SizedBox(width: 24),
                                  SizedBox(width: 320, child: sidebar),
                                ],
                              ),
                            );
                          }
                          return Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                mainContent,
                                const SizedBox(height: 24),
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
            ],
          ),
        );
      },
    );
  }

  Widget _buildDetailMainContent(BuildContext context, dynamic p) {
    final theme = Theme.of(context);
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
        // Price (with badges) and Stock
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _buildDetailPrice(theme, p),
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: p.inStock ? Colors.green : Colors.red,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    p.stockAmount ?? (p.inStock ? 'In Stock' : 'Out of Stock'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (p.category.isNotEmpty || p.sku != null) ...[
          Wrap(
            spacing: 8,
            children: [
              if (p.category.isNotEmpty)
                Chip(
                  avatar: const Icon(Icons.category, size: 18),
                  label: Text(decodeHtmlEntities(p.category)),
                ),
              if (p.sku != null)
                Chip(
                  avatar: const Icon(Icons.qr_code, size: 18),
                  label: Text('SKU: ${p.sku}'),
                ),
            ],
          ),
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
          ..._buildDescriptionParagraphs(context, p.description),
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
                        '${p.currency} ${v.price.toStringAsFixed(2)}',
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
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton.icon(
            onPressed: p.inStock
                ? () {
                    ref.read(cartProvider.notifier).add(p.id);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content:
                            Text('${decodeHtmlEntities(p.name)} added to cart'),
                        action: SnackBarAction(
                          label: 'View Cart',
                          onPressed: () => context.push(AppRoutes.cart),
                        ),
                      ),
                    );
                  }
                : null,
            icon: const Icon(Icons.shopping_cart),
            label: Text(p.inStock ? 'Add to Cart' : 'Out of Stock'),
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () async {
            final ok = await StoreLinkService.openAddToCart(p.id);
            if (!context.mounted) return;
            if (!ok) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                      'Could not open store. Visit qfurniture.com.au to buy.'),
                ),
              );
            }
          },
          icon: const Icon(Icons.open_in_browser, size: 20),
          label: const Text('Buy on store (qfurniture.com.au)'),
        ),
      ],
    );
  }

  Widget _buildDetailPrice(ThemeData theme, dynamic p) {
    if (p.onSale &&
        p.regularPrice != null &&
        p.salePrice != null &&
        p.regularPrice! > 0) {
      final pct =
          ((p.regularPrice! - p.salePrice!) / p.regularPrice! * 100).round();
      return Row(
        children: [
          Text(
            '${p.currency} ${p.salePrice!.toStringAsFixed(2)}',
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${p.currency} ${p.regularPrice!.toStringAsFixed(2)}',
            style: theme.textTheme.titleMedium?.copyWith(
              color: Colors.grey[600],
              decoration: TextDecoration.lineThrough,
            ),
          ),
          const SizedBox(width: 8),
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
      '${p.currency} ${p.price.toStringAsFixed(2)}',
      style: theme.textTheme.headlineMedium?.copyWith(
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.primary,
      ),
    );
  }

  Widget _buildDetailSidebar(BuildContext context, dynamic p) {
    final theme = Theme.of(context);
    final hasMaterial = p.material != null && p.material!.isNotEmpty;
    final hasInfo = p.assemblyRequired.isNotEmpty ||
        (p.color != null && p.color!.isNotEmpty) ||
        hasMaterial ||
        (p.dimensions != null && p.dimensions!.isNotEmpty) ||
        (p.weight != null && p.weight!.isNotEmpty);

    if (!hasMaterial && !hasInfo) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasMaterial) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.green.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${p.material} Timber Fact',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.green.shade800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _materialFactBlurb(p.material!),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.green.shade900,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (hasInfo) ...[
          Text(
            'Additional Information',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Table(
              columnWidths: const {
                0: FlexColumnWidth(1.2),
                1: FlexColumnWidth(1.8),
              },
              children: [
                if (p.assemblyRequired.isNotEmpty)
                  _infoRow('Assembly Required', p.assemblyRequired),
                if (p.color != null && p.color!.isNotEmpty)
                  _infoRow('Color', p.color!),
                if (p.material != null && p.material!.isNotEmpty)
                  _infoRow('Material', p.material!),
                if (p.dimensions != null && p.dimensions!.isNotEmpty)
                  _infoRow('Dimensions', p.dimensions!),
                if (p.weight != null && p.weight!.isNotEmpty)
                  _infoRow('Weight', p.weight!),
              ],
            ),
          ),
        ],
      ],
    );
  }

  TableRow _infoRow(String label, String value) {
    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Text(value, style: const TextStyle(fontSize: 13)),
        ),
      ],
    );
  }

  String _materialFactBlurb(String material) {
    final m = material.toLowerCase();
    if (m.contains('eucalyptus')) {
      return 'Eucalyptus is a fast-growing, highly dense hardwood and a sustainable alternative to slower-growing hardwoods.';
    }
    if (m.contains('acacia')) {
      return 'Acacia is a durable, responsibly sourced hardwood with natural resistance to insects and termites.';
    }
    if (m.contains('rubberwood')) {
      return 'Rubberwood is an eco-friendly hardwood from rubber tree plantations, known for durability and even grain.';
    }
    return '$material is a quality timber choice for furniture.';
  }

  String _detailImagePathAt(dynamic product, int index) {
    final images = product.images.isNotEmpty ? product.images : [product.image];
    if (index < images.length) {
      final fromJson = images[index];
      if (isImageUrl(fromJson)) return fromJson;
      return normalizeAssetPath(fromJson);
    }
    if (index == 0) {
      final ext = extensionFromPath(product.image.isNotEmpty
          ? product.image
          : product.images.isNotEmpty
              ? product.images.first
              : null);
      return normalizeAssetPath(
          productMainImagePath(product.sku, product.id, ext: ext));
    }
    final ext = extensionFromPath(
        index - 1 < images.length ? images[index - 1] : product.image);
    return normalizeAssetPath(
        productGalleryImagePath(product.sku, product.id, index - 1, ext: ext));
  }

  Widget _buildImageGallery(product) {
    final images = product.images.isNotEmpty ? product.images : [product.image];
    final count = images.isEmpty ? 1 : images.length;

    // Always use PageView so images are slidable (even with 1 image for consistency)
    return Stack(
      fit: StackFit.expand,
      children: [
        PageView.builder(
          controller: _pageController,
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
                          child:
                              const Center(child: CircularProgressIndicator()),
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
                    product.salePrice != null)
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
        // Page indicators (show when more than one image)
        if (count > 1)
          Positioned(
            bottom: 16,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                count,
                (index) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4.0),
                  child: Container(
                    width: _selectedImageIndex == index ? 24 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _selectedImageIndex == index
                          ? Colors.white
                          : Colors.white.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ),
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

  /// Strips HTML tags, decodes entities, and returns paragraph widgets.
  static List<Widget> _buildDescriptionParagraphs(
      BuildContext context, String htmlText) {
    if (htmlText.trim().isEmpty) return [];
    String s = htmlText
        .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    s = s
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'[ \t]+'), ' ');
    final plain = decodeHtmlEntities(s).trim();
    final style = Theme.of(context).textTheme.bodyLarge;
    final paragraphs = plain
        .split(RegExp(r'\n\s*\n'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (paragraphs.isEmpty) {
      return [Text(plain, style: style)];
    }
    return [
      for (int i = 0; i < paragraphs.length; i++) ...[
        Text(paragraphs[i], style: style),
        if (i < paragraphs.length - 1) const SizedBox(height: 12),
      ],
    ];
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
