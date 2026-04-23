import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config/store_config.dart';
import '../../../services/auth_service.dart';
import '../../../services/woo_commerce_rest_api.dart';

/// Required wholesale MOQ (AUD) from order history: first order 500, then 350.
final wholesaleMoqGateProvider =
    FutureProvider.autoDispose<({double requiredMoq, bool hasCompletedOrder})>(
        (ref) async {
  final s = AuthService.instance.currentSession;
  final token = s?.token;
  final role = s?.role.toLowerCase() ?? '';
  if (role != 'wholesale' || token == null || token.isEmpty) {
    return (requiredMoq: 0.0, hasCompletedOrder: false);
  }
  final cid = s?.customerId ??
      await AuthService.instance.ensureCustomerIdForCurrentSession();
  if (cid == null) {
    // Conservative default: first-order MOQ until customer linkage is known.
    return (
      requiredMoq: kWholesaleMinimumFirstOrderAud,
      hasCompletedOrder: false,
    );
  }
  final has = await WooCommerceRestApi.instance
      .customerHasCompletedOrder(jwt: token, customerId: cid);
  return (
    requiredMoq: has
        ? kWholesaleMinimumReturningOrderAud
        : kWholesaleMinimumFirstOrderAud,
    hasCompletedOrder: has,
  );
});
