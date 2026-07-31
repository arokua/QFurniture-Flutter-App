import '../../../services/auth_service.dart';
import '../../../services/cart_sync_service.dart';
import 'cart_coordinator.dart';
import 'cart_remote_gateway.dart';

CartCoordinator? _coordinator;

/// The app-wide cart engine.
///
/// Built here rather than inside [CartCoordinator] so the engine itself stays
/// free of singleton dependencies and remains testable with a fake gateway.
CartCoordinator get cartCoordinator => _coordinator ??= CartCoordinator(
      gateway: StoreCartApiGateway(
        isSignedInProvider: () => AuthService.instance.isSignedIn,
        ensureSessionCallback: () async {
          await AuthService.instance.ensureValidSession();
        },
      ),
      userKeyProvider: () => CartSyncService.instance.currentUserKey(),
    );

/// Starts the engine. Called once from `main`.
Future<void> initCartCoordinator() => cartCoordinator.start();

/// Test seam: drops the singleton so a fresh engine can be installed.
void resetCartCoordinatorForTest([CartCoordinator? replacement]) {
  _coordinator = replacement;
}
