import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config/store_config.dart';
import '../features/catalog/utils/asset_path.dart';

/// How many gallery images per product are stored on-device for offline/fast load.
const int kCachedImagesPerProduct = 5;

/// First catalogue batch size (product JSON, not images).
const int kInitialProductBatchSize = 20;

/// Downloads and stores the first [kCachedImagesPerProduct] remote images per
/// product under app documents. Indices 0–4 resolve to local files when cached;
/// index 5+ always uses the network URL at display time.
class ProductImageCacheService extends ChangeNotifier {
  ProductImageCacheService._();
  static final ProductImageCacheService instance = ProductImageCacheService._();

  static const _metaFileName = '_urls.json';

  Directory? _rootDir;
  final Set<String> _localKeys = {};
  final List<Map<String, dynamic>> _highQueue = [];
  final List<Map<String, dynamic>> _lowQueue = [];
  bool _workerRunning = false;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized || kIsWeb) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      _rootDir = Directory('${docs.path}/qf_product_images');
      await _rootDir!.create(recursive: true);
      await _scanExistingFiles();
      _initialized = true;
    } catch (e) {
      if (kDebugMode) debugPrint('[ProductImageCache] init error: $e');
    }
  }

  /// Synchronous lookup after [init]. Returns a file path for indices 0–4 only.
  String? localPath(int productId, int imageIndex) {
    if (kIsWeb || imageIndex < 0 || imageIndex >= kCachedImagesPerProduct) {
      return null;
    }
    final key = _key(productId, imageIndex);
    if (!_localKeys.contains(key)) return null;
    final path = _localFilePath(productId, imageIndex);
    if (path.isEmpty) return null;
    try {
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() < 64) {
        _localKeys.remove(key);
        return null;
      }
    } catch (_) {
      return null;
    }
    return path;
  }

  /// Whether display should prefer device storage (indices 0–4).
  bool shouldUseLocalCache(int imageIndex) =>
      imageIndex >= 0 && imageIndex < kCachedImagesPerProduct;

  /// Queue products for background image download. [highPriority] = first batch.
  void enqueueProductMaps(
    Iterable<Map<String, dynamic>> maps, {
    bool highPriority = false,
  }) {
    if (kIsWeb) return;
    final queue = highPriority ? _highQueue : _lowQueue;
    queue.addAll(maps);
    _startWorker();
  }

  void enqueueProductJson(Map<String, dynamic> map, {bool highPriority = false}) {
    enqueueProductMaps([map], highPriority: highPriority);
  }

  Future<void> _startWorker() async {
    if (_workerRunning || kIsWeb) return;
    await init();
    if (_rootDir == null) return;
    _workerRunning = true;
    try {
      while (_highQueue.isNotEmpty || _lowQueue.isNotEmpty) {
        final high = _highQueue.isNotEmpty;
        final map = high ? _highQueue.removeAt(0) : _lowQueue.removeAt(0);
        await _cacheProductMap(map, maxImages: high ? kCachedImagesPerProduct : 1);
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _workerRunning = false;
      if (_highQueue.isNotEmpty || _lowQueue.isNotEmpty) {
        _startWorker();
      }
    }
  }

  Future<void> _cacheProductMap(
    Map<String, dynamic> map, {
    int maxImages = kCachedImagesPerProduct,
  }) async {
    final id = map['id'];
    final productId = id is int ? id : int.tryParse('$id');
    if (productId == null || productId <= 0) return;

    final urls = _imageUrlsFromMap(map);
    if (urls.isEmpty) return;

    final dir = Directory('${_rootDir!.path}/$productId');
    await dir.create(recursive: true);

    final metaPath = File('${dir.path}/$_metaFileName');
    Map<String, dynamic> meta = {};
    if (metaPath.existsSync()) {
      try {
        meta = jsonDecode(await metaPath.readAsString()) as Map<String, dynamic>;
      } catch (_) {
        meta = {};
      }
    }

    var changed = false;
    final limit = maxImages.clamp(1, kCachedImagesPerProduct);
    final toCache = urls.take(limit).toList();
    for (var i = 0; i < toCache.length; i++) {
      final url = toCache[i];
      if (!isImageUrl(url)) continue;
      final prev = meta['$i']?.toString();
      if (prev == url && localPath(productId, i) != null) continue;

      final ok = await _downloadToFile(url, dir.path, productId, i);
      if (ok) {
        meta['$i'] = url;
        _localKeys.add(_key(productId, i));
        changed = true;
      }
    }

    if (changed) {
      await metaPath.writeAsString(jsonEncode(meta));
      notifyListeners();
    }
  }

  Future<bool> _downloadToFile(
    String url,
    String dirPath,
    int productId,
    int index,
  ) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
      }
      try {
        final response = await http
            .get(Uri.parse(url), headers: {'User-Agent': kAppUserAgent})
            .timeout(const Duration(seconds: 45));
        if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
          continue;
        }
        final ext = extensionFromPath(url);
        final path =
            '$dirPath${Platform.pathSeparator}$index.$ext';
        await File(path).writeAsBytes(response.bodyBytes, flush: true);
        _localKeys.add(_key(productId, index));
        return true;
      } catch (e) {
        if (kDebugMode && attempt == 2) {
          debugPrint('[ProductImageCache] download failed: $e');
        }
      }
    }
    return false;
  }

  List<String> _imageUrlsFromMap(Map<String, dynamic> map) {
    final urls = <String>[];
    final main = map['image']?.toString() ?? '';
    if (isImageUrl(main)) urls.add(main);

    final raw = map['images'];
    if (raw is List) {
      for (final item in raw) {
        final u = item is String
            ? item
            : (item is Map ? item['src']?.toString() : null);
        if (u != null && isImageUrl(u) && !urls.contains(u)) {
          urls.add(u);
        }
      }
    }
    return urls;
  }

  Future<void> _scanExistingFiles() async {
    _localKeys.clear();
    final root = _rootDir;
    if (root == null || !root.existsSync()) return;
    for (final entity in root.listSync()) {
      if (entity is! Directory) continue;
      final productId = int.tryParse(entity.path.split(Platform.pathSeparator).last);
      if (productId == null) continue;
      for (var i = 0; i < kCachedImagesPerProduct; i++) {
        final pattern = RegExp('^$i\\.\\w+\$');
        for (final f in entity.listSync()) {
          if (f is File && pattern.hasMatch(f.uri.pathSegments.last)) {
            _localKeys.add(_key(productId, i));
            break;
          }
        }
      }
    }
  }

  static String _key(int productId, int index) => '$productId:$index';

  String _localFilePath(int productId, int index) {
    final dir = _rootDir;
    if (dir == null) return '';
    final productDir = Directory('${dir.path}/$productId');
    if (!productDir.existsSync()) return '';
    final pattern = RegExp('^$index\\.\\w+\$');
    for (final f in productDir.listSync()) {
      if (f is File && pattern.hasMatch(f.uri.pathSegments.last)) {
        return f.path;
      }
    }
    return '';
  }
}
