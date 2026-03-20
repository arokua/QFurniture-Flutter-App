import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../utils/asset_path.dart';
import '../utils/html_utils.dart';
import '../../../providers.dart';
import '../../../config/store_config.dart';
import 'store_webview_screen.dart';
import '../domain/product.dart';

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
  bool _descriptionExpanded = false;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(productRepoProvider);
    return FutureBuilder<Product?>(
      future: repo.getById(widget.productId),
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(child: Text('Error: ${snap.error}')),
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
        return Scaffold(
          body: CustomScrollView(
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
        // Price
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(child: _buildDetailPrice(theme, p)),
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
                ? () => StoreWebViewScreen.push(context, storeAddToCartUrl(p.id, quantity: 1))
                : null,
            icon: const Icon(Icons.open_in_browser, size: 22),
            label: Text(p.inStock ? 'Check out on store' : 'Out of Stock'),
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        _buildProductBenefits(context),
      ],
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
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.eco, color: Colors.green.shade700, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${p.material} Timber Fact',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.green.shade900,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _materialFactBlurb(p.material!),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.green.shade800,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
        if (hasInfo) ...[
          Text(
            'Additional Details',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          if (p.assemblyRequired.isNotEmpty)
            _modernInfoRow(context, Icons.build_outlined, 'Assembly', p.assemblyRequired),
          if (p.color != null && p.color!.isNotEmpty)
            _modernInfoRow(context, Icons.color_lens_outlined, 'Color', p.color!),
          if (p.material != null && p.material!.isNotEmpty)
            _modernInfoRow(context, Icons.forest_outlined, 'Material', p.material!),
          if (p.dimensions != null && p.dimensions!.isNotEmpty)
            _modernInfoRow(context, Icons.straighten_outlined, 'Dimensions', p.dimensions!),
          if (p.weight != null && p.weight!.isNotEmpty)
            _modernInfoRow(context, Icons.scale_outlined, 'Weight', p.weight!),
        ],
      ],
    );
  }

  Widget _modernInfoRow(BuildContext context, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Colors.grey.shade600),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade700,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
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
