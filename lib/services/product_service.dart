import 'dart:async';
import 'package:ecommerce_int2/api_service.dart';
import 'package:ecommerce_int2/models/product.dart';
import 'package:ecommerce_int2/models/category.dart';

/// Service to manage products with auto-refresh capability
class ProductService {
  static final ProductService _instance = ProductService._internal();
  factory ProductService() => _instance;
  ProductService._internal();

  // Stream controllers for product updates
  final _productsController = StreamController<List<Product>>.broadcast();
  final _categoriesController = StreamController<List<Category>>.broadcast();
  
  // Current state
  List<Product> _cachedProducts = [];
  List<Category> _cachedCategories = [];
  Timer? _refreshTimer;
  
  // Streams
  Stream<List<Product>> get productsStream => _productsController.stream;
  Stream<List<Category>> get categoriesStream => _categoriesController.stream;
  
  // Getters for current state
  List<Product> get cachedProducts => List.unmodifiable(_cachedProducts);
  List<Category> get cachedCategories => List.unmodifiable(_cachedCategories);

  /// Initialize the service and start auto-refresh
  void initialize({Duration refreshInterval = const Duration(minutes: 5)}) {
    // Load initial data
    refreshProducts();
    refreshCategories();
    
    // Set up auto-refresh timer
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(refreshInterval, (_) {
      refreshProducts();
      refreshCategories();
    });
  }

  /// Refresh products from API
  Future<void> refreshProducts({int page = 1, int perPage = 20, String? category}) async {
    try {
      final products = await ApiService.getProducts(
        page: page,
        perPage: perPage,
        category: category,
      );
      
      if (category == null && page == 1) {
        // Update cached products for main list
        _cachedProducts = products;
        _productsController.add(products);
      } else {
        // Emit filtered/categorized products
        _productsController.add(products);
      }
    } catch (e) {
      print('Error refreshing products: $e');
      // Emit cached products on error
      if (_cachedProducts.isNotEmpty) {
        _productsController.add(_cachedProducts);
      }
    }
  }

  /// Refresh categories from API
  Future<void> refreshCategories({int? parent}) async {
    try {
      final categories = await ApiService.getCategories(parent: parent);
      _cachedCategories = categories;
      _categoriesController.add(categories);
    } catch (e) {
      print('Error refreshing categories: $e');
      // Emit cached categories on error
      if (_cachedCategories.isNotEmpty) {
        _categoriesController.add(_cachedCategories);
      }
    }
  }

  /// Get products by category
  Future<List<Product>> getProductsByCategory(String categorySlug) async {
    try {
      final products = await ApiService.getProductsByCategory(categorySlug);
      return products;
    } catch (e) {
      print('Error getting products by category: $e');
      return [];
    }
  }

  /// Search products
  Future<List<Product>> searchProducts(String query) async {
    try {
      final products = await ApiService.searchProducts(query);
      return products;
    } catch (e) {
      print('Error searching products: $e');
      return [];
    }
  }

  /// Get single product
  Future<Product?> getProduct(int productId) async {
    try {
      // Check cache first
      final cached = _cachedProducts.firstWhere(
        (p) => p.id == productId,
        orElse: () => Product(
          id: -1,
          sku: '',
          name: '',
          categories: [],
          images: [],
          regularPrice: '',
          salePrice: '',
          shortDescription: '',
          longDescription: '',
          material: null,
          age: null,
          dimensions: null,
          weight: null,
          assemblyRequired: false,
        ),
      );
      
      if (cached.id != -1) {
        return cached;
      }
      
      // Fetch from API if not in cache
      return await ApiService.getProduct(productId);
    } catch (e) {
      print('Error getting product: $e');
      return null;
    }
  }

  /// Manual refresh trigger (for pull-to-refresh)
  Future<void> forceRefresh() async {
    await Future.wait([
      refreshProducts(),
      refreshCategories(),
    ]);
  }

  /// Dispose resources
  void dispose() {
    _refreshTimer?.cancel();
    _productsController.close();
    _categoriesController.close();
  }
}
