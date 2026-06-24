import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../services/product_image_cache_service.dart';
import '../../domain/product.dart';
import '../../utils/asset_path.dart';

/// Renders a product image: bundled assets, on-device cache (indices 0–4),
/// or network URL (index 5+ always network).
class ProductDisplayImage extends StatelessWidget {
  const ProductDisplayImage({
    super.key,
    required this.product,
    this.imageIndex = 0,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.errorWidget,
  });

  final Product product;
  final int imageIndex;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? errorWidget;

  @override
  Widget build(BuildContext context) {
    final cache = ProductImageCacheService.instance;
    final remote = product.imageSourceAt(imageIndex);
    final useLocal = cache.shouldUseLocalCache(imageIndex);
    final localPath =
        useLocal ? cache.localPath(product.id, imageIndex) : null;

    if (localPath != null) {
      return Image.file(
        File(localPath),
        fit: fit,
        errorBuilder: (_, __, ___) => _buildRemoteOrAsset(remote),
      );
    }

    return _buildRemoteOrAsset(remote);
  }

  Widget _buildRemoteOrAsset(String source) {
    if (source.isEmpty) {
      return errorWidget ?? _defaultError();
    }
    if (isImageUrl(source)) {
      return CachedNetworkImage(
        imageUrl: source,
        fit: fit,
        placeholder: (_, __) => placeholder ?? _defaultPlaceholder(),
        errorWidget: (_, __, ___) => errorWidget ?? _defaultError(),
      );
    }
    return Image.asset(
      assetKeyForImage(normalizeAssetPath(source)),
      fit: fit,
      errorBuilder: (_, __, ___) => errorWidget ?? _defaultError(),
    );
  }

  Widget _defaultPlaceholder() => Container(
        color: Colors.grey[200],
        child: const Center(
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );

  Widget _defaultError() => Container(
        color: Colors.grey[200],
        child: const Icon(Icons.image_not_supported, color: Colors.grey),
      );
}

/// Listens for cache updates so thumbnails refresh when background downloads finish.
class ProductDisplayImageLive extends StatefulWidget {
  const ProductDisplayImageLive({
    super.key,
    required this.product,
    this.imageIndex = 0,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.errorWidget,
  });

  final Product product;
  final int imageIndex;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? errorWidget;

  @override
  State<ProductDisplayImageLive> createState() => _ProductDisplayImageLiveState();
}

class _ProductDisplayImageLiveState extends State<ProductDisplayImageLive> {
  @override
  void initState() {
    super.initState();
    ProductImageCacheService.instance.addListener(_onCacheUpdate);
  }

  @override
  void dispose() {
    ProductImageCacheService.instance.removeListener(_onCacheUpdate);
    super.dispose();
  }

  void _onCacheUpdate() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ProductDisplayImage(
      product: widget.product,
      imageIndex: widget.imageIndex,
      fit: widget.fit,
      placeholder: widget.placeholder,
      errorWidget: widget.errorWidget,
    );
  }
}
