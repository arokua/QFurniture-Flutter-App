import '../../../config/store_cart_api_service.dart';
import '../../../services/auth_service.dart';

/// Refreshes JWT validity and re-primes Woo Store API cookies / Cart-Token
/// before reading the remote cart. Required for background sync — a bare GET
/// /cart fails once the bridge session or cart token ages out.
Future<bool> refreshCartSession() async {
  if (!AuthService.instance.isSignedIn) return false;
  final sessionOk = await AuthService.instance.ensureValidSession();
  if (!sessionOk) return false;
  final jwt = AuthService.instance.jwtToken;
  StoreCartApiService.instance.setJwtToken(jwt);
  await StoreCartApiService.instance.bootstrapSessionFromJwt(jwt);
  return true;
}
