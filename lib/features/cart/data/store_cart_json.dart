import '../domain/cart_item.dart';

/// Parses WooCommerce Store API `GET /cart` JSON into local line items.
List<CartItem> cartItemsFromStoreCartJson(Map<String, dynamic> json) {
  final raw = json['items'];
  if (raw is! List) return [];
  final out = <CartItem>[];
  for (final e in raw) {
    if (e is! Map<String, dynamic>) continue;
    final id = e['id'];
    final qty = e['quantity'];
    int? pid;
    if (id is int) {
      pid = id;
    } else if (id != null) {
      pid = int.tryParse(id.toString());
    }
    if (pid == null) continue;
    final q = qty is int ? qty : int.tryParse(qty?.toString() ?? '') ?? 1;
    out.add(CartItem(productId: pid, quantity: q));
  }
  return out;
}

/// Shipping + totals from Store API `totals` block (amounts as strings in minor units).
class StoreCartTotalsView {
  const StoreCartTotalsView({
    required this.currencyCode,
    required this.currencySymbol,
    required this.minorUnit,
    required this.totalPriceMinor,
    required this.totalShippingMinor,
    required this.hasCalculatedShipping,
  });

  final String currencyCode;
  final String currencySymbol;
  final int minorUnit;
  final int? totalPriceMinor;
  final int? totalShippingMinor;
  final bool hasCalculatedShipping;

  static StoreCartTotalsView? fromCartJson(Map<String, dynamic> json) {
    final totals = json['totals'];
    if (totals is! Map<String, dynamic>) return null;
    final minor = totals['currency_minor_unit'];
    final mu = minor is int ? minor : int.tryParse(minor?.toString() ?? '') ?? 2;
    final code = totals['currency_code']?.toString() ?? 'AUD';
    final sym = totals['currency_symbol']?.toString() ?? r'$';
    final tp = _parseMinor(totals['total_price']);
    final ts = _parseMinor(totals['total_shipping']);
    final hasShip = json['has_calculated_shipping'] == true;
    return StoreCartTotalsView(
      currencyCode: code,
      currencySymbol: sym,
      minorUnit: mu,
      totalPriceMinor: tp,
      totalShippingMinor: ts,
      hasCalculatedShipping: hasShip,
    );
  }

  static int? _parseMinor(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    return int.tryParse(v.toString());
  }

  String? formatMinor(int? amountMinor) {
    if (amountMinor == null) return null;
    final divisor = _pow10(minorUnit);
    final major = amountMinor / divisor;
    return '$currencySymbol${major.toStringAsFixed(minorUnit)}';
  }

  int _pow10(int n) {
    var p = 1;
    for (var i = 0; i < n; i++) {
      p *= 10;
    }
    return p;
  }

  String? get shippingLine {
    if (!hasCalculatedShipping) {
      return 'Enter address at checkout for shipping';
    }
    if (totalShippingMinor == null) return null;
    if (totalShippingMinor == 0) {
      return 'Shipping: Free';
    }
    return 'Shipping: ${formatMinor(totalShippingMinor)}';
  }

  String? get orderTotalLine {
    if (totalPriceMinor == null) return null;
    return 'Order total (incl. tax): ${formatMinor(totalPriceMinor)}';
  }
}
