import 'store_cart_json.dart';

/// One line from WooCommerce Store API `GET /wc/store/v1/cart` `items[]`.
class StoreCartLineItem {
  const StoreCartLineItem({
    required this.productId,
    required this.quantity,
    required this.name,
    this.lineTotalMinor,
    this.currencySymbol,
  });

  final int productId;
  final int quantity;
  final String name;
  final int? lineTotalMinor;
  final String? currencySymbol;
}

/// Parsed display snapshot from Store API cart (authoritative when synced).
class StoreCartApiSnapshot {
  const StoreCartApiSnapshot({
    required this.totalsView,
    required this.lines,
  });

  final StoreCartTotalsView totalsView;
  final List<StoreCartLineItem> lines;

  /// First matching line per product id (Store API uses product id on lines).
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
    if (raw is! List) {
      return StoreCartApiSnapshot(totalsView: totals, lines: const []);
    }
    final lines = <StoreCartLineItem>[];
    for (final e in raw) {
      if (e is! Map<String, dynamic>) continue;
      final id = e['id'];
      int? pid;
      if (id is int) {
        pid = id;
      } else if (id != null) {
        pid = int.tryParse(id.toString());
      }
      if (pid == null) continue;
      final qtyRaw = e['quantity'];
      final q = qtyRaw is int
          ? qtyRaw
          : int.tryParse(qtyRaw?.toString() ?? '') ?? 1;
      final name = (e['name'] ?? e['short_description'] ?? '').toString().trim();
      final prices = e['prices'];
      int? lineMinor;
      String? sym;
      if (prices is Map<String, dynamic>) {
        final p = prices['line_price'] ?? prices['price'];
        if (p != null) {
          lineMinor = int.tryParse(p.toString().replaceAll(RegExp(r'[^\d-]'), ''));
        }
        sym = prices['currency_symbol']?.toString();
      }
      final itemTotals = e['totals'];
      if (itemTotals is Map<String, dynamic>) {
        final lt = itemTotals['line_total'] ?? itemTotals['line_subtotal'];
        if (lt != null) {
          lineMinor = int.tryParse(lt.toString().replaceAll(RegExp(r'[^\d-]'), ''));
        }
      }
      lines.add(StoreCartLineItem(
        productId: pid,
        quantity: q,
        name: name.isNotEmpty ? name : 'Product #$pid',
        lineTotalMinor: lineMinor,
        currencySymbol: sym,
      ));
    }
    return StoreCartApiSnapshot(totalsView: totals, lines: lines);
  }
}
