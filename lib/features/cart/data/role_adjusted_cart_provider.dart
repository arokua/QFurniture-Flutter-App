import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers.dart';
import '../../../services/auth_service.dart';
import '../domain/role_cart_pricing.dart';
import 'store_cart_snapshot.dart';
import 'woo_cart_provider.dart';

/// Store API cart with catalogue role/sale prices applied (wholesale 0.5×, dropship 0.55×, retail 1×).
final roleAdjustedCartSnapshotProvider =
    FutureProvider.autoDispose<StoreCartApiSnapshot?>((ref) async {
  final woo = await ref.watch(wooCartProvider.future);
  final snap = woo.snapshot;
  if (snap == null || snap.isEmpty) return snap;
  if (!AuthService.instance.isSignedIn) return snap;

  final role = AuthService.instance.currentSession?.role;
  final repo = ref.read(productRepoProvider);
  return RoleCartPricing.applyToSnapshot(snap, role, repo.getById);
});
