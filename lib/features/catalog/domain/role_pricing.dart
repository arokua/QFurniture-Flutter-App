/// Retailer list/sale prices from WooCommerce are the reference (1:1 = retail).
/// Tier multipliers: wholesale 0.5×, dropship 0.55× (1.1× wholesale), retail 1× (2× wholesale).
/// Sale items use [salePrice] × multiplier, not [regularPrice].
class RolePricing {
  RolePricing._();

  /// Multiplier applied to retailer reference prices (current, regular, sale).
  static double multiplierFor(String? role) {
    if (role == null || role.isEmpty) return 1.0;
    switch (role.toLowerCase()) {
      case 'wholesale':
        return 0.5;
      case 'dropshipping':
      case 'retailer':
        return 1;
      case 'administrator':
      case 'admin':
        return 0.75;
      case 'customers':
      case 'customer':
      default:
        return 1.0;
    }
  }

  static double roundMoney(double v) => (v * 100).round() / 100;
}
