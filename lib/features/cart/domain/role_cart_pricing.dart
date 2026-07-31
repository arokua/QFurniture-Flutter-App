import '../../catalog/domain/product.dart';
import '../../catalog/domain/role_pricing.dart';
import '../data/store_cart_json.dart';
import '../data/store_cart_snapshot.dart';

/// Role-tier cart/order amounts — matches catalogue [Product.displayCurrentPriceForRole].
class RoleCartPricing {
  RoleCartPricing._();

  static String moneyString(double amount, {int decimals = 2}) =>
      amount.toStringAsFixed(decimals);

  static int majorToMinor(double major, int minorUnit) {
    var mult = 1;
    for (var i = 0; i < minorUnit; i++) {
      mult *= 10;
    }
    return (RolePricing.roundMoney(major) * mult).round();
  }

  static double unitPrice(Product product, String? role) =>
      product.displayCurrentPriceForRole(role);

  static double lineTotal(Product product, String? role, int quantity) =>
      RolePricing.roundMoney(unitPrice(product, role) * quantity);

  /// Rebuild cart lines + item subtotal using catalogue role/sale prices (not Store API retail).
  static Future<StoreCartApiSnapshot> applyToSnapshot(
    StoreCartApiSnapshot snap,
    String? role,
    Future<Product?> Function(int productId) getProduct,
  ) async {
    if (snap.lines.isEmpty) return snap;

    final tv = snap.totalsView;
    final newLines = <StoreCartLineItem>[];
    var itemsMinor = 0;

    for (final line in snap.lines) {
      final product = await getProduct(line.productId);
      if (product == null) {
        newLines.add(line);
        itemsMinor += line.lineTotalMinor ??
            (line.priceMinor != null ? line.priceMinor! * line.quantity : 0);
        continue;
      }

      final unitMajor = unitPrice(product, role);
      final lineMajor = lineTotal(product, role, line.quantity);
      final unitMinor = majorToMinor(unitMajor, line.minorUnit);
      final lineMinor = majorToMinor(lineMajor, line.minorUnit);
      itemsMinor += lineMinor;

      newLines.add(
        StoreCartLineItem(
          productId: line.productId,
          quantity: line.quantity,
          name: line.name.isNotEmpty ? line.name : product.name,
          sku: line.sku ?? product.sku,
          cartItemKey: line.cartItemKey,
          priceMinor: unitMinor,
          lineTotalMinor: lineMinor,
          currencySymbol: line.currencySymbol ?? tv.currencySymbol,
          minorUnit: line.minorUnit,
          imageUrl: line.imageUrl ??
              (product.primaryImage.startsWith('http')
                  ? product.primaryImage
                  : null),
        ),
      );
    }

    final storeItemsMinor = tv.totalItemsMinor ?? 0;
    int? taxMinor = tv.totalTaxMinor;
    if (taxMinor != null && storeItemsMinor > 0 && itemsMinor != storeItemsMinor) {
      taxMinor = ((taxMinor * itemsMinor) / storeItemsMinor).round();
    }

    final shippingMinor = tv.totalShippingMinor ?? 0;
    final totalMinor = itemsMinor + (taxMinor ?? 0) + shippingMinor;

    final adjustedTotals = StoreCartTotalsView(
      currencyCode: tv.currencyCode,
      currencySymbol: tv.currencySymbol,
      minorUnit: tv.minorUnit,
      totalPriceMinor: totalMinor,
      totalShippingMinor: tv.totalShippingMinor,
      totalItemsMinor: itemsMinor,
      totalTaxMinor: taxMinor,
      hasCalculatedShipping: tv.hasCalculatedShipping,
    );

    return StoreCartApiSnapshot(
      totalsView: adjustedTotals,
      lines: newLines,
      errors: snap.errors,
    );
  }

  /// Build REST line prices from an already role-adjusted cart snapshot (no I/O).
  static List<RoleOrderLinePrice> fromSnapshotLines(
    List<StoreCartLineItem> lines,
  ) {
    final out = <RoleOrderLinePrice>[];
    for (final line in lines) {
      if (line.productId <= 0 || line.quantity <= 0) continue;

      var divisor = 1.0;
      for (var i = 0; i < line.minorUnit; i++) {
        divisor *= 10;
      }
      final unitMajor =
          line.priceMinor != null ? line.priceMinor! / divisor : 0.0;
      final lineMajor = line.lineTotalMinor != null
          ? line.lineTotalMinor! / divisor
          : RolePricing.roundMoney(unitMajor * line.quantity);

      out.add(
        RoleOrderLinePrice(
          productId: line.productId,
          quantity: line.quantity,
          unitPrice: moneyString(unitMajor),
          lineTotal: moneyString(lineMajor),
        ),
      );
    }
    return out;
  }

  /// Explicit WC REST line prices for order creation.
  static Future<List<RoleOrderLinePrice>> resolveOrderLinePrices({
    required List<({int productId, int quantity})> lines,
    required String? role,
    required Future<Product?> Function(int productId) getProduct,
  }) async {
    final out = <RoleOrderLinePrice>[];
    for (final line in lines) {
      if (line.productId <= 0 || line.quantity <= 0) continue;
      final product = await getProduct(line.productId);
      if (product == null) continue;
      final unit = unitPrice(product, role);
      final total = lineTotal(product, role, line.quantity);
      out.add(
        RoleOrderLinePrice(
          productId: line.productId,
          quantity: line.quantity,
          unitPrice: moneyString(unit),
          lineTotal: moneyString(total),
        ),
      );
    }
    return out;
  }
}

class RoleOrderLinePrice {
  const RoleOrderLinePrice({
    required this.productId,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
  });

  final int productId;
  final int quantity;
  final String unitPrice;
  final String lineTotal;
}
