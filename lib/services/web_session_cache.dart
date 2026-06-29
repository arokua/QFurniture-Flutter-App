import 'package:shared_preferences/shared_preferences.dart';

/// Tracks when the WebView last had a verified WP login (persisted across app restarts).
class WebSessionCache {
  WebSessionCache._();

  static const _prefsKey = 'qf_web_session_verified_ms';
  /// Align with extended app auth cookies on the server (14 days).
  static const Duration reuseTtl = Duration(days: 14);

  static DateTime? _lastVerifiedAt;
  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    final ms = _prefs?.getInt(_prefsKey);
    if (ms != null && ms > 0) {
      _lastVerifiedAt = DateTime.fromMillisecondsSinceEpoch(ms);
    }
  }

  static bool get isFresh {
    final at = _lastVerifiedAt;
    if (at == null) return false;
    return DateTime.now().difference(at) < reuseTtl;
  }

  static Future<void> markValid() async {
    _lastVerifiedAt = DateTime.now();
    await init();
    await _prefs?.setInt(
      _prefsKey,
      _lastVerifiedAt!.millisecondsSinceEpoch,
    );
  }

  static Future<void> clear() async {
    _lastVerifiedAt = null;
    await init();
    await _prefs?.remove(_prefsKey);
  }
}
