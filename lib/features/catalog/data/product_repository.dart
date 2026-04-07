import '../domain/product.dart';
import 'product_local_datasource.dart';
import 'product_remote_datasource.dart';

class ProductRepository {
  final ProductLocalDataSource local;
  final ProductRemoteDataSource remote;
  
  ProductRepository(this.local, this.remote);

  Future<List<Product>> getAll() async {
    // We rely on [local] which now correctly delegates to [ProductSyncService]
    // for network fetching (with pagination), caching, and asset fallback.
    return local.fetchProducts();
  }

  Future<Product?> getById(int id) async {
    Product? localProduct;
    try {
      localProduct = await local.fetchById(id);
    } catch (_) {}
    try {
      final remoteProduct = await remote.fetchById(id);
      if (remoteProduct != null) {
        // WooCommerce Store API often returns only the main image; use local gallery when we have more images.
        if (localProduct != null &&
            localProduct.images.length > remoteProduct.images.length) {
          return Product(
            id: remoteProduct.id,
            name: remoteProduct.name,
            price: remoteProduct.price,
            regularPrice: remoteProduct.regularPrice,
            salePrice: remoteProduct.salePrice,
            onSale: remoteProduct.onSale,
            currency: remoteProduct.currency,
            image: remoteProduct.image,
            images: localProduct.images,
            permalink: remoteProduct.permalink,
            inStock: remoteProduct.inStock,
            stockAmount: remoteProduct.stockAmount,
            category: remoteProduct.category,
            categoryList: remoteProduct.categoryList,
            age: remoteProduct.age,
            description: remoteProduct.description,
            sku: remoteProduct.sku,
            variants: remoteProduct.variants,
            material: remoteProduct.material,
            assemblyRequired: remoteProduct.assemblyRequired,
            color: remoteProduct.color,
            weight: remoteProduct.weight,
            dimensions: remoteProduct.dimensions,
          );
        }
        return remoteProduct;
      }
    } catch (_) {}
    return localProduct;
  }
}
