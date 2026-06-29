import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../config/store_config.dart';
import 'web_session_cache.dart';

/// Persisted WordPress login cookies (`wordpress_logged_in_*`, `wordpress_sec_*`)
/// so the in-app WebView can reopen already logged in without re-running the bridge.
class WebAuthCookieStore {
  WebAuthCookieStore._();

  static const _prefsKey = 'qf_web_auth_cookies_v1';
  static SharedPreferences? _prefs;
  static List<StoredWebCookie> _cache = const [];

  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    final raw = _prefs?.getString(_prefsKey);
    if (raw == null || raw.isEmpty) {
      _cache = const [];
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        _cache = const [];
        return;
      }
      _cache = decoded
          .whereType<Map<String, dynamic>>()
          .map(StoredWebCookie.fromJson)
          .where((c) => c.name.isNotEmpty && c.value.isNotEmpty)
          .toList();
    } catch (_) {
      _cache = const [];
    }
  }

  static bool get hasStoredAuth =>
      _cache.any((c) => _isAuthCookieName(c.name));

  static Future<void> clear() async {
    _cache = const [];
    await _prefs?.remove(_prefsKey);
    WebSessionCache.clear();
  }

  static bool _isAuthCookieName(String name) {
    final lower = name.toLowerCase();
    return lower.startsWith('wordpress_logged_in') ||
        lower.startsWith('wordpress_sec_');
  }

  static Future<void> saveFromSetCookieHeader(String header) async {
    final parsed = _parseSetCookieHeader(header);
    if (parsed == null || !_isAuthCookieName(parsed.name)) return;
    await _upsert(parsed);
  }

  static Future<void> saveFromHttpHeaders(HttpHeaders headers) async {
    final headersList = <String>[];
    headers.forEach((name, values) {
      if (name.toLowerCase() != 'set-cookie') return;
      headersList.addAll(values);
    });
    for (final h in headersList) {
      await saveFromSetCookieHeader(h);
    }
  }

  static StoredWebCookie? _parseSetCookieHeader(String header) {
    final parts = header.split(';').map((s) => s.trim()).toList();
    if (parts.isEmpty) return null;
    final nv = parts.first.split('=');
    if (nv.length < 2) return null;
    final name = nv[0].trim();
    final value = nv.sublist(1).join('=').trim();
    if (name.isEmpty || value.isEmpty) return null;
    var path = '/';
    for (final attr in parts.skip(1)) {
      final lower = attr.toLowerCase();
      if (lower.startsWith('path=')) {
        path = attr.substring(5).trim();
      }
    }
    return StoredWebCookie(name: name, value: value, path: path);
  }

  static Future<void> _upsert(StoredWebCookie cookie) async {
    await init();
    final next = <StoredWebCookie>[
      for (final c in _cache)
        if (c.name != cookie.name) c,
      cookie,
    ];
    _cache = next;
    await _prefs?.setString(
      _prefsKey,
      jsonEncode(next.map((c) => c.toJson()).toList()),
    );
    if (kDebugMode) {
      debugPrint('[WebAuthCookie] saved ${cookie.name}');
    }
  }

  /// Inject stored WP auth cookies into the WebView jar before loading pages.
  static Future<void> injectInto(WebViewCookieManager cookieManager) async {
    if (kIsWeb) return;
    await init();
    if (_cache.isEmpty) return;
    final domain = Uri.parse(kStoreBaseUrl).host;
    for (final c in _cache) {
      if (!_isAuthCookieName(c.name)) continue;
      try {
        await cookieManager.setCookie(
          WebViewCookie(
            name: c.name,
            value: c.value,
            domain: domain,
            path: c.path.isEmpty ? '/' : c.path,
          ),
        );
      } catch (e) {
        if (kDebugMode) debugPrint('[WebAuthCookie] inject error: $e');
      }
    }
  }
}

class StoredWebCookie {
  const StoredWebCookie({
    required this.name,
    required this.value,
    this.path = '/',
  });

  final String name;
  final String value;
  final String path;

  factory StoredWebCookie.fromJson(Map<String, dynamic> j) => StoredWebCookie(
        name: (j['name'] ?? '').toString(),
        value: (j['value'] ?? '').toString(),
        path: (j['path'] ?? '/').toString(),
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'value': value,
        'path': path,
      };
}
