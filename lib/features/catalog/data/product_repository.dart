import '../domain/product.dart';
import 'product_local_datasource.dart';

class ProductRepository {
  final ProductLocalDataSource local;
  ProductRepository(this.local);

  Future<List<Product>> getAll() => local.fetchProducts();
  Future<Product?> getById(int id) => local.fetchById(id);
}
