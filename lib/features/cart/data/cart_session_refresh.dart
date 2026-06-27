import '../../../config/store_cart_api_service.dart';
import '../../../services/auth_service.dart';

/// Refresh JWT only — does not re-run the cookie bridge (that would wipe Cart-Token).
Future<bool> ensureCartJwtFresh() async {
  if (!AuthService.instance.isSignedIn) return false;
  final sessionOk = await AuthService.instance.ensureValidSession();
  if (!sessionOk) return false;
  StoreCartApiService.instance.setJwtToken(AuthService.instance.jwtToken);
  return true;
}

/// Full JWT bridge + cart prime. Use on login, pull-to-refresh, or fetch retry only.
Future<bool> rebootstrapCartSession() async {
  if (!await ensureCartJwtFresh()) return false;
  return StoreCartApiService.instance
      .bootstrapSessionFromJwt(AuthService.instance.jwtToken);
}
