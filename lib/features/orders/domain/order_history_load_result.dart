import 'woo_order_summary.dart';

class OrderHistoryLoadResult {
  const OrderHistoryLoadResult({
    required this.orders,
    this.webViewFallback = false,
  });

  final List<WooOrderSummary> orders;
  final bool webViewFallback;
}
