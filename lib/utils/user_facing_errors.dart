/// Maps technical HTTP / WordPress REST errors to copy safe for end users.
/// Raw messages like "No route was found matching the URL and method" must not
/// appear in the UI (they confuse users and look like app bugs).

String sanitizeAuthApiMessage(String raw) {
  final clean = raw.replaceAll(RegExp(r'<[^>]*>'), '').trim();
  if (clean.isEmpty) return 'Something went wrong. Please try again.';
  final l = clean.toLowerCase();
  if (l.contains('no route was found') ||
      l.contains('rest_no_route') ||
      l.contains('matching the url and method')) {
    return 'Cannot reach the store right now. Check your connection or try again later.';
  }
  if (l.contains('network error') ||
      l.contains('socketexception') ||
      l.contains('failed host lookup') ||
      l.contains('connection refused') ||
      l.contains('timed out')) {
    return 'No connection. Try again when you are online.';
  }
  return clean;
}

/// For catalog / generic async failures (Riverpod, FutureBuilder).
String userFacingCatalogError(Object? error, {String fallback = 'Could not load content.'}) {
  final s = error?.toString() ?? '';
  final l = s.toLowerCase();
  if (l.contains('no route was found') ||
      l.contains('rest_no_route') ||
      l.contains('matching the url')) {
    return 'Catalogue is temporarily unavailable. Showing cached items when possible.';
  }
  if (l.contains('socketexception') ||
      l.contains('failed host lookup') ||
      l.contains('network') && l.contains('error')) {
    return 'You appear to be offline. Cached catalogue may still be available.';
  }
  return fallback;
}
