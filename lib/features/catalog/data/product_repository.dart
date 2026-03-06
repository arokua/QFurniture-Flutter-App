import '../domain/product.dart';
import 'product_local_datasource.dart';
import 'product_remote_datasource.dart';

class ProductRepository {
  final ProductLocalDataSource local;
  final ProductRemoteDataSource remote;
  
  ProductRepository(this.local, this.remote);

  Future<List<Product>> getAll() async {
    try {
      final remoteProducts = await remote.fetchProducts();
      if (remoteProducts.isNotEmpty) return remoteProducts;
    } catch (_) {
      // Fallback to local
    }
    return local.fetchProducts();
  }

  Future<Product?> getById(int id) async {
    try {
      final remoteProduct = await remote.fetchById(id);
      if (remoteProduct != null) return remoteProduct;
    } catch (_) {
      // Fallback to local
    }
    return local.fetchById(id);
  }
}
