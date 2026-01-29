/// A single line in the cart: product id and quantity.
class CartItem {
  const CartItem({required this.productId, this.quantity = 1});

  final int productId;
  final int quantity;

  CartItem copyWith({int? productId, int? quantity}) {
    return CartItem(
      productId: productId ?? this.productId,
      quantity: quantity ?? this.quantity,
    );
  }
}
