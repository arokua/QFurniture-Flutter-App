/// In-memory hint that the in-app WebView recently had a valid WP login cookie.
/// Avoids re-running the full JWT bridge on every WebView open in the same session.
class WebSessionCache {
  WebSessionCache._();

  static DateTime? _lastVerifiedAt;
  static const Duration reuseTtl = Duration(minutes: 30);

  static bool get isFresh {
    final at = _lastVerifiedAt;
    if (at == null) return false;
    return DateTime.now().difference(at) < reuseTtl;
  }

  static void markValid() => _lastVerifiedAt = DateTime.now();

  static void clear() => _lastVerifiedAt = null;
}
