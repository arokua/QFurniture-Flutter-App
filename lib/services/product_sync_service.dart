import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/store_config.dart';
import '../features/catalog/data/category_repository.dart';
import '../features/catalog/domain/role_pricing.dart';
import '../features/catalog/utils/html_utils.dart';
import 'auth_service.dart';
import 'product_image_cache_service.dart';

/// WooCommerce Store API product sync with phased download:
/// 1) [kInitialSyncCategorySlug] products first (fast first paint on fresh install)
/// 2) Full catalogue in a detached background task (signed-in users only)
///
/// Guests may preview up to [guestPreviewProductLimit] newest products without login.
class ProductSyncService extends ChangeNotifier {
  ProductSyncService._();
  static final ProductSyncService instance = ProductSyncService._();

  static const String _cacheKey = 'qf_product_cache_v2';
  static const String _cacheFileName = 'qf_product_cache_v2.json';
  static const String _cacheTimestampKey = 'qf_product_cache_ts_v2';
  static const int _cacheTtlHours = 12;
  static const int _backgroundRefreshHours = 2;
  static const int _perPage = 100;

  /// Checkpoint cache to disk every N pages during background sync.
  static const int _saveEveryPages = 5;

  /// First network batch for quick startup (New Arrivals category on cold install).
  static const int initialSyncBatchSize = kInitialCategoryBatchSize;

  /// Unauthenticated catalogue preview cap.
  static const int guestPreviewProductLimit = 30;

  static const Duration _backgroundPageDelay = Duration(milliseconds: 80);

  final CategoryRepository _categoryRepo = CategoryRepository();

  static String get _remoteEndpoint =>
      '$kStoreBaseUrl/wp-json/wc/store/v1/products';

  bool _syncInFlight = false;
  bool _initialBatchReady = false;
  bool _fullCatalogReady = false;
  bool _isLoadingInitial = false;
  bool _isSyncingRest = false;
  int _loadedCount = 0;
  int? _reportedTotal;
  String? _statusMessage;
  int? _bootstrapCategoryId;
  String? _bootstrapCategoryName;

  /// Category used for the first paint on a cold install (when resolved).
  int? get bootstrapCategoryId => _bootstrapCategoryId;
  String? get bootstrapCategoryName => _bootstrapCategoryName;

  /// Lightweight, high-frequency progress signal for the status strip.
  /// Updated on every page so the UI bar animates WITHOUT forcing the heavy
  /// product-list provider (full JSON decode + Product.fromJson) to re-run.
  final ValueNotifier<String?> syncStatus = ValueNotifier<String?>(null);
  final ValueNotifier<double?> syncProgress = ValueNotifier<double?>(null);

  bool get initialBatchReady => _initialBatchReady;
  bool get fullCatalogReady => _fullCatalogReady;
  bool get isLoadingInitial => _isLoadingInitial;
  bool get isSyncingRest => _isSyncingRest;
  int get loadedCount => _loadedCount;
  int? get reportedTotal => _reportedTotal;
  String? get statusMessage => _statusMessage;

  bool get isBackgroundSyncing =>
      _isLoadingInitial || _isSyncingRest;

  /// True while only the bootstrap category batch is cached (full sync still running).
  bool get isPartialCatalog =>
      _initialBatchReady && !_fullCatalogReady && AuthService.instance.isSignedIn;

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Start phased sync after auth is known. Safe to call multiple times.
  Future<void> ensureCatalogLoaded({bool force = false}) async {
    if (_syncInFlight && !force) return;
    final prefs = await SharedPreferences.getInstance();
    final cachedJson = await _readCacheJson(prefs);
    final cachedTs = prefs.getInt(_cacheTimestampKey) ?? 0;
    final ageHours =
        (DateTime.now().millisecondsSinceEpoch - cachedTs) / (1000 * 3600);

    if (!force &&
        cachedJson != null &&
        ageHours < _cacheTtlHours &&
        AuthService.instance.isSignedIn) {
      final decoded = _decode(cachedJson);
      _loadedCount = decoded.length;
      _initialBatchReady = true;
      _fullCatalogReady = true;
      _setStatus('Catalogue ready (${decoded.length} products)');
      notifyListeners();
      if (ageHours > _backgroundRefreshHours) {
        _refreshFullCatalogInBackground(prefs);
      }
      ProductImageCacheService.instance.enqueueProductMaps(decoded);
      return;
    }

    if (!force && cachedJson != null && !AuthService.instance.isSignedIn) {
      final decoded = _decode(cachedJson);
      if (decoded.isNotEmpty) {
        _loadedCount = decoded.length.clamp(0, guestPreviewProductLimit);
        _initialBatchReady = true;
        _fullCatalogReady = true;
        _setStatus('Preview catalogue ready');
        notifyListeners();
        ProductImageCacheService.instance.enqueueProductMaps(decoded);
        return;
      }
    }

    await _runPhasedSync(prefs, force: force);
  }

  /// Returns the best available product JSON list (may be partial while syncing).
  Future<List<Map<String, dynamic>>> getProducts() async {
    final prefs = await SharedPreferences.getInstance();
    final cachedJson = await _readCacheJson(prefs);

    if (cachedJson != null) {
      final list = _decode(cachedJson);
      if (list.isNotEmpty) {
        _loadedCount = list.length;
        if (!AuthService.instance.isSignedIn) {
          return _limitPreviewNewest(list);
        }
        return list;
      }
    }

    if (!_syncInFlight) {
      ensureCatalogLoaded().ignore();
    }

    // Avoid parsing the 3 MB bundled asset during an active network sync.
    if (_syncInFlight || _isSyncingRest) {
      return [];
    }

    try {
      final bundled = await _loadBundledAsset();
      if (bundled.isNotEmpty) {
        if (!AuthService.instance.isSignedIn) {
          return _limitPreviewNewest(bundled);
        }
        return bundled;
      }
    } catch (_) {}

    return [];
  }

  Future<void> forceRefresh() async {
    final prefs = await SharedPreferences.getInstance();
    await _deleteCacheFiles(prefs);
    _initialBatchReady = false;
    _fullCatalogReady = false;
    await _runPhasedSync(prefs, force: true);
  }

  Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await _deleteCacheFiles(prefs);
    _initialBatchReady = false;
    _fullCatalogReady = false;
    _loadedCount = 0;
    notifyListeners();
  }

  List<Map<String, dynamic>> _limitPreviewNewest(
    List<Map<String, dynamic>> products,
  ) {
    final sorted = List<Map<String, dynamic>>.from(products);
    sorted.sort((a, b) {
      final da = _modifiedMs(a);
      final db = _modifiedMs(b);
      return db.compareTo(da);
    });
    if (sorted.length <= guestPreviewProductLimit) return sorted;
    return sorted.sublist(0, guestPreviewProductLimit);
  }

  static int _modifiedMs(Map<String, dynamic> p) {
    final raw = p['modified']?.toString() ?? '';
    final parsed = DateTime.tryParse(raw);
    return parsed?.millisecondsSinceEpoch ?? 0;
  }

  // ── Phased sync ─────────────────────────────────────────────────────────────

  Future<void> _runPhasedSync(SharedPreferences prefs, {required bool force}) async {
    if (_syncInFlight) return;
    _syncInFlight = true;
    _isLoadingInitial = true;
    _isSyncingRest = false;
    _initialBatchReady = false;
    _fullCatalogReady = false;
    _bootstrapCategoryId = null;
    _bootstrapCategoryName = null;
    _setStatus('Loading latest products…');
    notifyListeners();

    try {
      final signedIn = AuthService.instance.isSignedIn;
      _RemoteBatch initial;

      if (signedIn) {
        final category = await _categoryRepo
            .resolveCategoryBySlug(kInitialSyncCategorySlug);
        if (category != null) {
          _bootstrapCategoryId = category.id;
          _bootstrapCategoryName = category.name;
          initial = await _fetchRemotePage(
            page: 1,
            perPage: initialSyncBatchSize,
            categoryId: category.id,
          );
        } else {
          initial = await _fetchRemotePage(
            page: 1,
            perPage: initialSyncBatchSize,
          );
        }
      } else {
        initial = await _fetchRemotePage(
          page: 1,
          perPage: guestPreviewProductLimit,
        );
      }

      if (initial.items.isNotEmpty) {
        await _saveCache(prefs, initial.items);
        _loadedCount = initial.items.length;
        _reportedTotal = initial.total;
        _initialBatchReady = true;
        _setStatus(
          signedIn
              ? 'Loaded $_loadedCount in ${_bootstrapCategoryName ?? "What's New"} — syncing full catalogue…'
              : 'Preview: $_loadedCount products (sign in for full catalogue)',
        );
        notifyListeners();
        ProductImageCacheService.instance.enqueueProductMaps(
          initial.items,
          highPriority: true,
        );
      }

      if (!signedIn) {
        _fullCatalogReady = true;
        return;
      }

      if (initial.items.isEmpty) {
        _setStatus('Syncing full catalogue…');
      }

      _startBackgroundFullSync(
        prefs: prefs,
        seed: initial.items,
      );
    } catch (_) {
      final cachedJson = await _readCacheJson(prefs);
      if (cachedJson != null) {
        final list = _decode(cachedJson);
        _loadedCount = list.length;
        _initialBatchReady = list.isNotEmpty;
        _fullCatalogReady = _initialBatchReady;
        _setStatus(
          list.isEmpty
              ? 'Could not load catalogue — showing offline data if available'
              : 'Showing cached catalogue ($_loadedCount products)',
        );
      } else {
        final bundled = await _loadBundledAsset();
        if (bundled.isNotEmpty) {
          await _saveCache(prefs, bundled);
          _loadedCount = bundled.length;
          _initialBatchReady = true;
          _fullCatalogReady = true;
          _setStatus('Showing bundled catalogue');
        }
      }
    } finally {
      _isLoadingInitial = false;
      if (!_isSyncingRest) {
        _syncInFlight = false;
      }
      notifyListeners();
    }
  }

  /// Detached full-catalog sync — does not block splash / first navigation.
  void _startBackgroundFullSync({
    required SharedPreferences prefs,
    required List<Map<String, dynamic>> seed,
  }) {
    Future.microtask(() async {
      if (_isSyncingRest) return;
      _isSyncingRest = true;
      _syncInFlight = true;
      notifyListeners();
      try {
        final rest = await _fetchRemainingAfterInitial(
          prefs: prefs,
          existing: seed,
        );
        if (rest.isNotEmpty) {
          await _saveCache(prefs, rest);
          _loadedCount = rest.length;
          ProductImageCacheService.instance.enqueueProductMaps(rest);
        }
        _fullCatalogReady = true;
        _setStatus('Catalogue ready ($_loadedCount products)');
      } catch (_) {
        if (_loadedCount > 0) {
          _fullCatalogReady = true;
          _setStatus('Showing partial catalogue ($_loadedCount products)');
        }
      } finally {
        _isSyncingRest = false;
        _syncInFlight = false;
        notifyListeners();
      }
    });
  }

  void _refreshFullCatalogInBackground(SharedPreferences prefs) {
    if (_syncInFlight) return;
    Future.microtask(() async {
      _syncInFlight = true;
      _isSyncingRest = true;
      _setStatus('Refreshing stock & prices…');
      notifyListeners();
      try {
        final cachedJson = await _readCacheJson(prefs);
        final cached = cachedJson != null ? _decode(cachedJson) : <Map<String, dynamic>>[];
        final byId = <int, Map<String, dynamic>>{};
        for (final p in cached) {
          final id = p['id'];
          if (id is int) byId[id] = Map<String, dynamic>.from(p);
        }

        var page = 1;
        var updated = 0;
        while (true) {
          final batch = await _fetchRemotePage(page: page, perPage: _perPage);
          if (batch.items.isEmpty) break;
          for (final remote in batch.items) {
            final id = remote['id'];
            if (id is! int) continue;
            final existing = byId[id];
            if (existing == null) {
              byId[id] = remote;
              updated++;
              ProductImageCacheService.instance.enqueueProductMaps([remote]);
            } else if (_applyIncrementalProductUpdate(existing, remote)) {
              updated++;
            }
          }
          if (batch.totalPages != null && page >= batch.totalPages!) break;
          page++;
          await Future<void>.delayed(Duration.zero);
        }

        if (byId.isNotEmpty) {
          final list = byId.values.toList();
          await _saveCache(prefs, list);
          _loadedCount = list.length;
          _fullCatalogReady = true;
          _setStatus(
            updated > 0
                ? 'Catalogue updated ($_loadedCount products, $updated changed)'
                : 'Catalogue ready ($_loadedCount products)',
          );
        }
      } catch (_) {
      } finally {
        _isSyncingRest = false;
        _syncInFlight = false;
        notifyListeners();
      }
    });
  }

  /// Updates stock/price fields in [local]. Returns true when anything changed.
  /// When the remote image list differs, prepends new URLs at indices 0..n-1
  /// and queues image downloads for those slots only.
  bool _applyIncrementalProductUpdate(
    Map<String, dynamic> local,
    Map<String, dynamic> remote,
  ) {
    var changed = false;

    void setIfDifferent(String key, dynamic value) {
      if (local[key] != value) {
        local[key] = value;
        changed = true;
      }
    }

    setIfDifferent('price', remote['price']);
    setIfDifferent('regularPrice', remote['regularPrice']);
    setIfDifferent('salePrice', remote['salePrice']);
    setIfDifferent('onSale', remote['onSale']);
    setIfDifferent('rolePrices', remote['rolePrices']);
    setIfDifferent('inStock', remote['inStock']);
    setIfDifferent('stockAmount', remote['stockAmount']);
    setIfDifferent('modified', remote['modified']);
    setIfDifferent('currency', remote['currency']);

    final oldImages = _imageUrlList(local['images']);
    final remoteImages = _imageUrlList(remote['images']);
    if (!_imageUrlListsEqual(oldImages, remoteImages)) {
      final merged = _mergeNewImagesToFront(oldImages, remoteImages);
      local['images'] = merged;
      final primary = merged.isNotEmpty ? merged.first : local['image'];
      setIfDifferent('image', primary);
      ProductImageCacheService.instance.enqueueProductMaps([local]);
    }

    return changed;
  }

  static List<String> _imageUrlList(dynamic raw) {
    if (raw is! List) return const [];
    return raw.map((e) => e.toString()).where((u) => u.isNotEmpty).toList();
  }

  static bool _imageUrlListsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// New remote URLs (not in [local]) are placed at indices 0..n-1; remainder kept.
  static List<String> _mergeNewImagesToFront(
    List<String> local,
    List<String> remote,
  ) {
    final newOnes = <String>[];
    for (final u in remote) {
      if (!local.contains(u)) newOnes.add(u);
    }
    if (newOnes.isEmpty) return remote;
    final tail = [
      ...local.where((u) => !newOnes.contains(u)),
      ...remote.where((u) => !newOnes.contains(u) && !local.contains(u)),
    ];
    return [...newOnes, ...tail];
  }

  Future<List<Map<String, dynamic>>> _fetchRemainingAfterInitial({
    required SharedPreferences prefs,
    required List<Map<String, dynamic>> existing,
  }) async {
    final byId = <int, Map<String, dynamic>>{};
    for (final p in existing) {
      final id = p['id'];
      if (id is int) byId[id] = p;
    }

    var page = 1;
    int? maxPages;
    int? catalogTotal;

    while (true) {
      final batch = await _fetchRemotePage(page: page, perPage: _perPage);
      if (batch.items.isEmpty) break;
      maxPages ??= batch.totalPages;
      catalogTotal ??= batch.total;
      for (final p in batch.items) {
        final id = p['id'];
        if (id is int) byId[id] = p;
      }
      _loadedCount = byId.length;
      if (catalogTotal != null) _reportedTotal = catalogTotal;

      _setStatus('Syncing catalogue… $_loadedCount of ${catalogTotal ?? '?'}');
      syncProgress.value = (catalogTotal != null && catalogTotal > 0)
          ? (_loadedCount / catalogTotal).clamp(0.0, 1.0)
          : null;

      if (page % _saveEveryPages == 0) {
        await _saveCache(prefs, byId.values.toList());
      }
      final lastPage = maxPages ?? batch.totalPages;
      if (lastPage != null && page >= lastPage) break;
      page++;
      await Future<void>.delayed(_backgroundPageDelay);
    }

    return byId.values.toList();
  }

  Future<_RemoteBatch> _fetchRemotePage({
    required int page,
    required int perPage,
    int? categoryId,
  }) async {
    final params = <String, String>{
      'page': '$page',
      'per_page': '$perPage',
      'orderby': 'date',
      'order': 'desc',
    };
    if (categoryId != null && categoryId > 0) {
      params['category'] = '$categoryId';
    }
    final uri = Uri.parse(_remoteEndpoint).replace(queryParameters: params);

    final response = await http
        .get(uri, headers: {'User-Agent': kAppUserAgent})
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      return const _RemoteBatch(items: [], total: null, totalPages: null);
    }

    final list = jsonDecode(response.body) as List<dynamic>;
    final items = list
        .cast<Map<String, dynamic>>()
        .map(_normalizeRemoteProduct)
        .toList();

    final total = int.tryParse(response.headers['x-wp-total'] ?? '');
    final totalPages = int.tryParse(response.headers['x-wp-totalpages'] ?? '');

    return _RemoteBatch(
      items: items,
      total: total,
      totalPages: totalPages,
    );
  }

  void _setStatus(String message) {
    _statusMessage = message;
    syncStatus.value = message;
  }

  // ── Normalization & cache (unchanged behaviour) ─────────────────────────────

  Map<String, dynamic> _normalizeRemoteProduct(Map<String, dynamic> p) {
    final rawImages = (p['images'] as List? ?? []);
    final imageUrls = rawImages
        .map((img) =>
            img is Map ? (img['src'] ?? '').toString() : img.toString())
        .where((u) => u.isNotEmpty)
        .toList();

    final rawCats = (p['categories'] as List? ?? []);
    final cats = rawCats
        .map((c) => c is Map ? (c['name'] ?? '').toString() : c.toString())
        .where((c) => c.isNotEmpty)
        .toList();

    final pricesObj = p['prices'] as Map<String, dynamic>? ?? {};
    double parseP(dynamic v) {
      if (v == null) return 0.0;
      if (v is num) {
        final d = v.toDouble();
        if (d >= 100 && d == d.truncateToDouble()) return d / 100;
        return d;
      }
      final s = v.toString().replaceAll(RegExp(r'[^\d.]'), '');
      final d = double.tryParse(s) ?? 0.0;
      if (d >= 100 && !v.toString().contains('.')) return d / 100;
      return d;
    }

    final price = parseP(p['price'] ?? pricesObj['price']);
    final regularPrice =
        parseP(p['regular_price'] ?? pricesObj['regular_price']);
    final salePrice = parseP(p['sale_price'] ?? pricesObj['sale_price']);
    final bool onSale = p['on_sale'] == true ||
        (salePrice > 0 && regularPrice > salePrice);

    final stockAvail = p['stock_availability'];
    final apiStockAmountText =
        stockAvail is Map ? stockAvail['text']?.toString() : null;
    final stockQuantity = p['stock_quantity'];
    String? stockAmount;

    if (apiStockAmountText != null && apiStockAmountText.trim().isNotEmpty) {
      stockAmount = normalizeStockDisplay(apiStockAmountText.trim());
    } else if (stockQuantity != null) {
      final quantity = int.tryParse(stockQuantity.toString());
      if (quantity != null && quantity > 0) {
        stockAmount = '$quantity in stock';
      }
    }

    String? material, color, assemblyRequired;
    for (final a in (p['attributes'] as List? ?? [])) {
      if (a is! Map) continue;
      final slug = (a['slug'] ?? a['taxonomy'] ?? '').toString().toLowerCase();
      final terms = a['terms'] as List? ?? [];
      final firstVal = terms.isNotEmpty && terms.first is Map
          ? terms.first['name']?.toString()
          : null;
      if (slug.contains('material')) material = firstVal;
      if (slug.contains('color') || slug.contains('colour')) color = firstVal;
      if (slug.contains('assembly')) assemblyRequired = firstVal;
    }

    String sku = (p['sku'] ?? '').toString().trim();
    if (sku.isEmpty) {
      for (final m in (p['meta_data'] as List? ?? [])) {
        if (m is! Map) continue;
        final key = m['key']?.toString().toLowerCase() ?? '';
        if (key == 'sku' || key == '_sku') {
          final v = m['value'];
          sku = v?.toString().trim() ?? '';
          if (sku.isNotEmpty) break;
        }
      }
    }
    if (sku.isEmpty) sku = '${p['id']}';

    final rolePrices = _rolePricesSnapshot(
      price: price,
      regularPrice: regularPrice,
      salePrice: salePrice,
      onSale: onSale,
    );

    return {
      'id': p['id'],
      'slug': p['slug'] ?? '',
      'name': p['name'] ?? '',
      'sku': sku,
      'permalink': p['permalink'] ?? p['link'] ?? p['url'] ?? p['guid'],
      'description': (p['description'] ?? '').toString().trim(),
      'shortDescription': (p['short_description'] ?? '').toString().trim(),
      'price': price,
      'regularPrice': regularPrice,
      'salePrice': salePrice,
      'onSale': onSale,
      'rolePrices': rolePrices,
      'currency': pricesObj['currency_code'] ?? 'AUD',
      'categories': cats,
      'category': cats.join(', '),
      'image': imageUrls.isNotEmpty ? imageUrls.first : '',
      'images': imageUrls,
      'inStock': p['is_in_stock'] ?? true,
      'stockAmount': stockAmount,
      'material': material,
      'assemblyRequired': assemblyRequired ?? 'Yes',
      'color': color,
      'weight': p['weight']?.toString(),
      'dimensions': _formatDimensions(p['dimensions']),
      'variants': p['variations'] ?? [],
      'modified': p['date_modified_gmt'],
    };
  }

  static Map<String, dynamic> _rolePricesSnapshot({
    required double price,
    required double regularPrice,
    required double salePrice,
    required bool onSale,
  }) {
    double current() => onSale && salePrice > 0 ? salePrice : price;
    double regular() => regularPrice;
    double? sale() => onSale && salePrice > 0 ? salePrice : null;

    Map<String, double> tier(double m) {
      final map = <String, double>{
        'price': RolePricing.roundMoney(current() * m),
        'regularPrice': RolePricing.roundMoney(regular() * m),
      };
      final s = sale();
      if (s != null) map['salePrice'] = RolePricing.roundMoney(s * m);
      return map;
    }

    return {
      'retailer': tier(1.0),
      'wholesale': tier(0.5),
      'dropship': tier(0.55),
      'admin': tier(0.75),
    };
  }

  String? _formatDimensions(dynamic dim) {
    if (dim == null) return null;
    if (dim is String) return dim.trim().isEmpty ? null : dim.trim();
    if (dim is Map) {
      final parts = ['length', 'width', 'height']
          .map((k) => dim[k]?.toString().trim() ?? '')
          .where((v) => v.isNotEmpty)
          .toList();
      return parts.isEmpty ? null : parts.join(' x ');
    }
    return null;
  }

  Future<File> _cacheFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}/$_cacheFileName');
  }

  /// Product JSON lives on disk — iOS UserDefaults rejects blobs >= 4 MB.
  Future<String?> _readCacheJson(SharedPreferences prefs) async {
    try {
      final file = await _cacheFile();
      if (await file.exists()) {
        final text = await file.readAsString();
        if (text.isNotEmpty) return text;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[ProductSync] file cache read error: $e');
    }

    // One-time migration from legacy SharedPreferences storage.
    final legacy = prefs.getString(_cacheKey);
    if (legacy != null && legacy.isNotEmpty) {
      try {
        final file = await _cacheFile();
        await file.writeAsString(legacy, flush: true);
        await prefs.remove(_cacheKey);
        if (kDebugMode) {
          debugPrint('[ProductSync] migrated catalog cache from prefs to file');
        }
        return legacy;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[ProductSync] prefs→file migration failed: $e');
        }
        return legacy;
      }
    }
    return null;
  }

  Future<void> _deleteCacheFiles(SharedPreferences prefs) async {
    await prefs.remove(_cacheKey);
    await prefs.remove(_cacheTimestampKey);
    try {
      final file = await _cacheFile();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> _saveCache(
    SharedPreferences prefs,
    List<Map<String, dynamic>> products,
  ) async {
    final encoded = jsonEncode(products);
    final file = await _cacheFile();
    await file.writeAsString(encoded, flush: true);
    await prefs.remove(_cacheKey);
    await prefs.setInt(
      _cacheTimestampKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  List<Map<String, dynamic>> _decode(String json) {
    try {
      final list = jsonDecode(json) as List<dynamic>;
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _loadBundledAsset() async {
    for (final path in [
      'assets/data/products.json',
      'assets/dummy_data.json',
    ]) {
      try {
        final raw = await rootBundle.loadString(path);
        final list = jsonDecode(raw) as List<dynamic>;
        return list.cast<Map<String, dynamic>>();
      } catch (_) {}
    }
    return [];
  }
}

class _RemoteBatch {
  const _RemoteBatch({
    required this.items,
    required this.total,
    required this.totalPages,
  });

  final List<Map<String, dynamic>> items;
  final int? total;
  final int? totalPages;
}
