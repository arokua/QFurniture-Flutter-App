import 'store_cart_json.dart';

/// One line from WooCommerce Store API `GET /wc/store/v1/cart` `items[]`.
class StoreCartLineItem {
  const StoreCartLineItem({
    required this.productId,
    required this.quantity,
    required this.name,
    this.sku,
    this.priceMinor,
    this.lineTotalMinor,
    this.currencySymbol,
    this.minorUnit = 2,
    this.imageUrl,
  });

  final int productId;
  final int quantity;
  final String name;

  /// WooCommerce product SKU.
  final String? sku;

  /// Unit price in minor units (e.g. cents). From `prices.price`.
  final int? priceMinor;

  /// Line total in minor units. From `totals.line_total`.
  final int? lineTotalMinor;

  final String? currencySymbol;

  /// Number of decimal places for the currency (e.g. 2 for AUD/USD).
  final int minorUnit;

  /// Cover image URL.
  final String? imageUrl;

  double get _divisor {
    var d = 1.0;
    for (var i = 0; i < minorUnit; i++) {
      d *= 10;
    }
    return d;
  }

  /// Unit price as a formatted string, e.g. "\$12.99".
  String? get formattedUnitPrice {
    if (priceMinor == null) return null;
    final sym = currencySymbol ?? r'$';
    return '$sym${(priceMinor! / _divisor).toStringAsFixed(minorUnit)}';
  }

  /// Line total as a formatted string, e.g. "\$25.98".
  String? get formattedLineTotal {
    if (lineTotalMinor == null) return null;
    final sym = currencySymbol ?? r'$';
    return '$sym${(lineTotalMinor! / _divisor).toStringAsFixed(minorUnit)}';
  }
}

/// Parsed display snapshot from Store API cart (authoritative when synced).
class StoreCartApiSnapshot {
  const StoreCartApiSnapshot({
    required this.totalsView,
    required this.lines,
    this.errors = const [],
  });

  final StoreCartTotalsView totalsView;
  final List<StoreCartLineItem> lines;
  final List<String> errors;

  bool get isEmpty => lines.isEmpty;

  /// First matching line per product id.
  Map<int, StoreCartLineItem> get byProductId {
    final m = <int, StoreCartLineItem>{};
    for (final l in lines) {
      m.putIfAbsent(l.productId, () => l);
    }
    return m;
  }

  static StoreCartApiSnapshot? fromCartJson(Map<String, dynamic> json) {
    final totals = StoreCartTotalsView.fromCartJson(json);
    if (totals == null) return null;
    final raw = json['items'];
    
    final errorsRaw = json['errors'];
    final parsedErrors = <String>[];
    if (errorsRaw is List) {
      for (final err in errorsRaw) {
        if (err is Map && err['message'] != null) {
          parsedErrors.add(err['message'].toString());
        }
      }
    }

    if (raw is! List) {
      return StoreCartApiSnapshot(totalsView: totals, lines: const [], errors: parsedErrors);
    }

    final lines = <StoreCartLineItem>[];
    for (final e in raw) {
      if (e is! Map<String, dynamic>) continue;

      // Product ID
      final id = e['id'];
      int? pid;
      if (id is int) {
        pid = id;
      } else if (id != null) {
        pid = int.tryParse(id.toString());
      }
      if (pid == null) continue;

      // Quantity
      final qtyRaw = e['quantity'];
      final q = qtyRaw is int
          ? qtyRaw
          : int.tryParse(qtyRaw?.toString() ?? '') ?? 1;

      // Name
      final name = (e['name'] ?? e['short_description'] ?? '').toString().trim();

      // SKU
      final sku = e['sku']?.toString().trim();

      // Prices block
      final prices = e['prices'];
      int? priceMinor;
      String? sym;
      int minorUnit = 2;
      if (prices is Map<String, dynamic>) {
        // Unit price (prefer sale_price if present, fall back to price)
        final priceRaw = prices['sale_price'] ?? prices['price'];
        if (priceRaw != null) {
          priceMinor = int.tryParse(
              priceRaw.toString().replaceAll(RegExp(r'[^\d-]'), ''));
        }
        sym = prices['currency_symbol']?.toString();
        final mu = prices['currency_minor_unit'];
        if (mu is int) {
          minorUnit = mu;
        } else if (mu != null) {
          minorUnit = int.tryParse(mu.toString()) ?? 2;
        }
      }

      // Totals block — line total overrides price-derived estimate
      int? lineTotalMinor;
      final itemTotals = e['totals'];
      if (itemTotals is Map<String, dynamic>) {
        final lt = itemTotals['line_total'] ?? itemTotals['line_subtotal'];
        if (lt != null) {
          lineTotalMinor =
              int.tryParse(lt.toString().replaceAll(RegExp(r'[^\d-]'), ''));
        }
      }
      
      // Image
      String? imageUrl;
      final images = e['images'];
      if (images is List && images.isNotEmpty) {
        final firstImg = images.first;
        if (firstImg is Map) {
          imageUrl = firstImg['src']?.toString();
        }
      }

      lines.add(StoreCartLineItem(
        productId: pid,
        quantity: q,
        name: name.isNotEmpty ? name : 'Product #$pid',
        sku: (sku != null && sku.isNotEmpty) ? sku : null,
        priceMinor: priceMinor,
        lineTotalMinor: lineTotalMinor,
        currencySymbol: sym,
        minorUnit: minorUnit,
        imageUrl: imageUrl,
      ));
    }

    return StoreCartApiSnapshot(totalsView: totals, lines: lines, errors: parsedErrors);
  }
}
