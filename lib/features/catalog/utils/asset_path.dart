import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;

/// Sanitize for path: same as download_product_images.py (replace non-word except - and . with _).
String sanitizeForPath(String s) {
  if (s.isEmpty) return 'unknown';
  return s.replaceAll(RegExp(r'[^\w\-.]'), '_');
}

/// Product folder name from sku or id, matching download script.
String productFolder(String? sku, int id) {
  final raw =
      (sku != null && sku.trim().isNotEmpty) ? sku.trim() : id.toString();
  return sanitizeForPath(raw);
}

/// Main image path: assets/products/{folder}/image_main_{folder}.{ext}
/// Same construction as download_product_images.py.
String productMainImagePath(String? sku, int id, {String ext = 'jpg'}) {
  final folder = productFolder(sku, id);
  return 'assets/products/$folder/image_main_$folder.$ext';
}

/// Gallery image path: assets/products/{folder}/gallery/image_gallery-{id}-{folder}-{index}.{ext}
String productGalleryImagePath(String? sku, int id, int index,
    {String ext = 'jpg'}) {
  final folder = productFolder(sku, id);
  return 'assets/products/$folder/gallery/image_gallery-$id-$folder-$index.$ext';
}

/// Whether the value looks like a URL (http/https).
bool isImageUrl(String? path) =>
    path != null && path.trim().toLowerCase().startsWith(RegExp(r'https?://'));

/// Extract file extension from path for product images (jpg, png, webp, gif).
/// Same as download_product_images.py. Defaults to 'jpg' if unknown.
String extensionFromPath(String? path) {
  if (path == null || path.isEmpty) return 'jpg';
  final lower = path.toLowerCase();
  if (lower.contains('.webp')) return 'webp';
  if (lower.contains('.png')) return 'png';
  if (lower.contains('.gif')) return 'gif';
  if (lower.contains('.jpg') || lower.contains('.jpeg')) return 'jpg';
  return 'jpg';
}

/// Normalize asset path: JSON may have "products/..." (no assets/ prefix).
/// Flutter bundle keys are "assets/products/...", so ensure local paths start with "assets/".
String normalizeAssetPath(String? path) {
  if (path == null || path.isEmpty || isImageUrl(path)) return path ?? '';
  final p = path.trim();
  if (p.startsWith('assets/')) return p;
  if (p.startsWith('products/')) return 'assets/$p';
  return p;
}

/// Resolve path for Image.asset: normalize then return (ensure one "assets/" prefix).
String resolveAssetPath(String? path) {
  return normalizeAssetPath(path);
}

/// Key to pass to Image.asset(). On web, Flutter builds URL as base + "assets/" + key,
/// so we must pass key WITHOUT leading "assets/" to avoid "assets/assets/...".
/// The bundle must have keys "products/..." (add products/ dirs in pubspec; symlink products -> assets/products).
String assetKeyForImage(String path) {
  if (path.isEmpty) return path;
  if (kIsWeb && path.startsWith('assets/')) {
    return path.substring(7);
  }
  return path;
}

/// Set to true to print image path construction to the console (debug only).
bool kDebugProductImagePaths = false;

/// Call from list/detail screens to log the path used for a product image.
void debugLogProductImagePath({
  required String screen,
  required int productId,
  required String? sku,
  required String? jsonImage,
  required String? jsonImagesLength,
  required String folder,
  required String pathUsed,
  required bool isUrl,
  int? imageIndex,
}) {
  if (!kDebugProductImagePaths) return;
  debugPrint('[$screen] productId=$productId sku=${sku ?? "(null)"} '
      'json.image=$jsonImage json.images.length=$jsonImagesLength '
      'folder=$folder pathUsed=$pathUsed isUrl=$isUrl${imageIndex != null ? " imageIndex=$imageIndex" : ""}');
}
