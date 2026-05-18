import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/store_cart_api_service.dart';
import '../config/store_config.dart';
import '../utils/user_facing_errors.dart';

// ─────────────────────────────────────────────────────────────────────────────
// AuthService
//
// Uses WordPress JWT Authentication for login and WooCommerce REST API
// for customer registration. Requires the "JWT Authentication for WP
// REST API" plugin active on the WordPress site.
// ─────────────────────────────────────────────────────────────────────────────

/// Auth service backed by WP JWT + WooCommerce REST API.
class AuthService extends ChangeNotifier {
  AuthService._();
  static final AuthService instance = AuthService._();

  static const _emailKey = 'qf_auth_email';
  static const _nameKey = 'qf_auth_name';
  static const _roleKey = 'qf_auth_role';
  static const _loggedInKey = 'qf_auth_loggedin';
  static const _tokenKey = 'qf_auth_token';
  static const _customerIdKey = 'qf_auth_customer_id';
  static const _webLoginEmailKey = 'qf_auth_web_login_email';
  static const _webLoginPasswordKey = 'qf_auth_web_login_password';
  /// PWA-style offline browse: use catalog/cached data without WordPress login (no network).
  static const _guestBrowseKey = 'qf_auth_guest_browse';

  SharedPreferences? _prefs;
  final _sessionController = StreamController<UserSession?>.broadcast();
  String? _lastAuthEmail;
  String? _lastAuthPassword;

  // ── Initialisation ───────────────────────────────────────────────────────

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _lastAuthEmail = _prefs!.getString(_webLoginEmailKey);
    _lastAuthPassword = _prefs!.getString(_webLoginPasswordKey);
    // Restore persisted session
    final isLoggedIn = _prefs!.getBool(_loggedInKey) ?? false;
    if (isLoggedIn) {
      final token = _prefs!.getString(_tokenKey);
      _sessionController.add(UserSession(
        email: _prefs!.getString(_emailKey) ?? '',
        displayName: _prefs!.getString(_nameKey) ?? '',
        role: _prefs!.getString(_roleKey) ?? 'customers',
        token: token,
        customerId: _prefs!.getInt(_customerIdKey),
      ));
      // Restore JWT to StoreCartApiService so API requests are authenticated
      // even after an app restart (token is already persisted in prefs).
      StoreCartApiService.instance.setJwtToken(token);
      StoreCartApiService.setJwtFallback(token);
    } else {
      _sessionController.add(null);
    }
    notifyListeners();
  }

  // ── Session stream ───────────────────────────────────────────────────────

  Stream<UserSession?> get sessionStream => _sessionController.stream;

  UserSession? get currentSession {
    final loggedIn = _prefs?.getBool(_loggedInKey) ?? false;
    if (!loggedIn) return null;
    return UserSession(
      email: _prefs?.getString(_emailKey) ?? '',
      displayName: _prefs?.getString(_nameKey) ?? '',
      role: _prefs?.getString(_roleKey) ?? 'customers',
      token: _prefs?.getString(_tokenKey),
      customerId: _prefs?.getInt(_customerIdKey),
    );
  }

  /// True when the user completed WordPress / WooCommerce login (has a stored session).
  bool get isSignedIn => currentSession != null;

  /// Offline / guest browse (cached catalogue, no account) — persisted across restarts.
  bool get isGuestBrowse => _prefs?.getBool(_guestBrowseKey) ?? false;

  /// Full catalogue, categories tab, cart checkout, etc.
  bool get canAccessApp => isSignedIn;

  /// Guest may open the catalog tab and preview the latest products (see product sync).
  bool get canPreviewCatalog => !isSignedIn;

  /// Identifies if the signed-in user is a wholesale account.
  bool get isWholesaleUser =>
      currentSession?.role.toLowerCase() == 'wholesale';
  bool get hasWebLoginCredentials =>
      (_lastAuthEmail != null && _lastAuthEmail!.isNotEmpty) &&
      (_lastAuthPassword != null && _lastAuthPassword!.isNotEmpty);
  String? get webLoginEmail => _lastAuthEmail;
  String? get webLoginPassword => _lastAuthPassword;
  String? get jwtToken => _prefs?.getString(_tokenKey);

  /// WooCommerce `my-account/?action=login&type=` — wholesale | dropship | customer.
  String get webAccountTypeForStoreLogin {
    final r = _prefs?.getString(_roleKey) ?? 'customers';
    switch (r) {
      case 'wholesale':
        return 'wholesale';
      case 'dropshipping':
      case 'retailer':
        return 'dropship';
      default:
        return 'customer';
    }
  }

  // ── Auth operations ──────────────────────────────────────────────────────

  /// Sign in with email + password via WordPress JWT endpoint.
  Future<AuthResult> signIn({
    required String email,
    required String password,
  }) async {
    return _loginWordPress(email: email, password: password);
  }

  /// Register a new account via WooCommerce REST API.
  Future<AuthResult> signUp({
    required String username,
    required String email,
    required String password,
    String? firstName,
    String role = 'customers',
    String? phone,
    String? abn,
    String? websiteUrl,
  }) async {
    final result = await _registerWooCustomer(
      username: username,
      email: email,
      password: password,
      firstName: firstName,
      role: role,
      phone: phone,
      abn: abn,
      websiteUrl: websiteUrl,
    );

    if (result.isSuccess && result.session != null) {
      await _persist(
        email: result.session!.email,
        name: result.session!.displayName,
        role: result.session!.role,
        token: result.session!.token,
        customerId: result.session!.customerId,
      );
    }
    return result;
  }

  /// Browse catalogue offline without signing in (no network call). Persists like a PWA shell.
  Future<void> enterGuestBrowseMode() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setBool(_guestBrowseKey, true);
    notifyListeners();
  }

  /// Sign out (clears real session and guest browse).
  Future<void> signOut() async {
    await _prefs?.remove(_emailKey);
    await _prefs?.remove(_nameKey);
    await _prefs?.remove(_roleKey);
    await _prefs?.remove(_tokenKey);
    await _prefs?.remove(_customerIdKey);
    await _prefs?.setBool(_loggedInKey, false);
    await _prefs?.setBool(_guestBrowseKey, false);
    _lastAuthEmail = null;
    _lastAuthPassword = null;
    await _prefs?.remove(_webLoginEmailKey);
    await _prefs?.remove(_webLoginPasswordKey);
    _sessionController.add(null);
    notifyListeners();
    // Guest cart in prefs can stay; Woo session cookie must not bleed to next user.
    // Also clear JWT token so next session doesn't inherit old credentials.
    try {
      StoreCartApiService.instance.setJwtToken(null);
      StoreCartApiService.setJwtFallback(null);
      await StoreCartApiService.instance.clearSession();
      await StoreCartApiService.instance.clearEmbeddedWebViewCookies();
    } catch (_) {}
  }

  /// Ensure signed-in session has a WooCommerce customer id.
  /// Some JWT plugins omit it from token response; resolve lazily from Woo endpoints.
  Future<int?> ensureCustomerIdForCurrentSession({bool force = false}) async {
    final session = currentSession;
    if (session == null) return null;
    if (!force && session.customerId != null) return session.customerId;
    final token = session.token?.trim();
    if (token == null || token.isEmpty) return null;

    try {
      final jwtPayload = _decodeJwtPayload(token);
      Map<String, dynamic>? customer =
          await _fetchWooCustomerByJwt(token, jwtPayload);
      customer ??= await _fetchWooCustomerByEmail(session.email);
      final cid = customer?['id'];
      final customerId = cid is int ? cid : (cid is num ? cid.toInt() : null);
      if (customerId == null) return null;

      await _persist(
        email: session.email,
        name: session.displayName,
        role: session.role,
        token: token,
        customerId: customerId,
      );
      return customerId;
    } catch (_) {
      return null;
    }
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  /// Authenticate against WP JWT endpoint.
  Future<AuthResult> _loginWordPress({
    required String email,
    required String password,
  }) async {
    final url = Uri.parse('$kStoreBaseUrl/wp-json/jwt-auth/v1/token');

    try {
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'User-Agent': kAppUserAgent,
        },
        body: jsonEncode({
          'username': email,
          'password': password,
        }),
      ).timeout(const Duration(seconds: 15));

      Map<String, dynamic>? data;
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          data = decoded;
        }
      } catch (_) {
        data = null;
      }

      if (data == null) {
        final bodyHead = response.body.trimLeft();
        final isHtml = bodyHead.startsWith('<!DOCTYPE html') ||
            bodyHead.startsWith('<html');
        if (kDebugMode) {
          final snippet = response.body.length > 300
              ? response.body.substring(0, 300)
              : response.body;
          debugPrint(
            '[Auth] jwt token endpoint returned non-JSON '
            'status=${response.statusCode} contentType=${response.headers['content-type']} '
            'isHtml=$isHtml body=$snippet',
          );
        }
        final msg = isHtml
            ? 'Login is temporarily unavailable (store returned HTML instead of API JSON). Please try again shortly.'
            : 'Login failed: unexpected server response.';
        return AuthResult.failure(sanitizeAuthApiMessage(msg));
      }

      if (response.statusCode == 200 && data['token'] != null) {
        final token = data['token'] as String;
        final userEmail = data['user_email'] as String? ?? email;
        final displayName = data['user_display_name'] as String? ?? email.split('@').first;

        if (kDebugMode) {
          final safe = Map<String, dynamic>.from(data);
          if (safe['token'] is String) {
            final t = safe['token'] as String;
            safe['token'] = t.length > 24 ? '${t.substring(0, 12)}…(len=${t.length})' : '***';
          }
          debugPrint('[Auth] jwt-auth/v1/token 200 keys: ${safe.keys.toList()}');
          debugPrint('[Auth] jwt-auth/v1/token body (token redacted): ${jsonEncode(safe)}');
        }

        // Role: merge WooCommerce customer + JWT (WP often reports `customer` while meta/JWT has wholesale).
        String role = 'customers';
        int? customerId;
        final jwtPayload = _decodeJwtPayload(token);
        if (kDebugMode && jwtPayload != null) {
          debugPrint('[Auth] JWT payload (decoded): ${jsonEncode(jwtPayload)}');
        }
        final jwtRoles = jwtPayload != null
            ? _extractRoleStringsFromJwt(jwtPayload)
            : const <String>[];

        // Some JWT setups inject `roles` into the token endpoint response JSON
        // (via filters like `jwt_auth_token_before_dispatch`) but not into the
        // actual JWT payload. We merge both sources so the UI role chip is correct.
        final tokenResponseRoles = _extractRoleStringsFromTokenResponseBody(data);
        if (kDebugMode) {
          debugPrint('[Auth] token response role strings extracted: $tokenResponseRoles');
        }

        final allRoleStrings = <String>[
          ...jwtRoles,
          ...tokenResponseRoles,
        ];
        if (kDebugMode) {
          debugPrint('[Auth] JWT role strings extracted: $jwtRoles');
          debugPrint('[Auth] merged role strings for resolution: $allRoleStrings');
        }
        final wpUserId = _wpUserIdFromJwtPayload(jwtPayload);
        if (kDebugMode && wpUserId != null) {
          debugPrint('[Auth] WP user id from JWT payload: $wpUserId');
        }

        try {
          Map<String, dynamic>? custResult =
              await _fetchWooCustomerByJwt(token, jwtPayload);
          custResult ??= await _fetchWooCustomerByEmail(userEmail);
          if (custResult != null) {
            final fromMap = _roleFromWooCustomerMap(custResult);
            if (fromMap != null && fromMap.isNotEmpty) {
              role = _normalizeStoredRole(fromMap);
            }
            customerId = custResult['id'] as int?;
            if (kDebugMode) {
              debugPrint(
                '[Auth] WC customer resolved: id=$customerId role_field=${custResult['role']} '
                'meta_keys=${_metaKeysSample(custResult)}',
              );
            }
          } else if (kDebugMode) {
            debugPrint(
              '[Auth] WC customer: no record from JWT /me, /id, or email search — using JWT roles only',
            );
          }

          // Extra fallback: WordPress user endpoint often exposes `roles` and/or `capabilities`
          // under context=edit. Useful when WooCommerce customer role is generic `customer`.
          if (wpUserId != null) {
            final wpUser = await _fetchWpUserById(token, wpUserId);
            if (wpUser != null) {
              final wpRoleStrings = _extractRoleStringsFromWpUser(wpUser);
              if (kDebugMode) {
                debugPrint(
                  '[Auth] WP user roles/capabilities extracted: $wpRoleStrings',
                );
              }
              for (final raw in wpRoleStrings) {
                final jr = _normalizeStoredRole(raw);
                role = _pickHigherPriorityRole(role, jr);
              }
            }
          }
        } catch (e, st) {
          if (kDebugMode) debugPrint('[Auth] WC customer fetch error: $e\n$st');
        }
        for (final raw in allRoleStrings) {
          final jr = _normalizeStoredRole(raw);
          role = _pickHigherPriorityRole(role, jr);
        }
        if (kDebugMode) {
          debugPrint('[Auth] Final resolved role for UI: $role');
        }

        _lastAuthEmail = email;
        _lastAuthPassword = password;
        await _prefs?.setString(_webLoginEmailKey, email);
        await _prefs?.setString(_webLoginPasswordKey, password);
        await _persist(
          email: userEmail,
          name: displayName,
          role: role,
          token: token,
          customerId: customerId,
        );
        // Allow StoreCartApiService to send JWT Bearer header, so the
        // audit-checkout.php plugin lets authenticated requests through
        // without requiring Cart-Token / Nonce session headers.
        StoreCartApiService.instance.setJwtToken(token);
        StoreCartApiService.setJwtFallback(token);

        return AuthResult.success(UserSession(
          email: userEmail,
          displayName: displayName,
          role: role,
          token: token,
          customerId: customerId,
        ));
      } else {
        // WP JWT returns error in different formats
        final msg = data['message'] ??
            data['data']?['message'] ??
            'Invalid email or password.';
        // Strip any HTML tags WP might include in error messages
        final cleanMsg = msg.toString().replaceAll(RegExp(r'<[^>]*>'), '');
        return AuthResult.failure(sanitizeAuthApiMessage(cleanMsg));
      }
    } catch (e, st) {
      debugPrint('Auth signIn error: $e\n$st');
      return AuthResult.failure(sanitizeAuthApiMessage(e.toString()));
    }
  }

  static Map<String, dynamic>? _decodeJwtPayload(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      var output = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      switch (output.length % 4) {
        case 2:
          output += '==';
          break;
        case 3:
          output += '=';
          break;
        case 1:
          return null;
      }
      final json = utf8.decode(base64Decode(output));
      return jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Collect all role-like strings from JWT (WordPress often sends `roles`: [...]).
  static List<String> _extractRoleStringsFromJwt(Map<String, dynamic> payload) {
    final out = <String>[];
    void add(dynamic v) {
      if (v is String && v.trim().isNotEmpty) out.add(v);
    }

    final data = payload['data'];
    if (data is Map<String, dynamic>) {
      final user = data['user'];
      if (user is Map<String, dynamic>) {
        add(user['role']);
        final roles = user['roles'];
        if (roles is List) {
          for (final e in roles) {
            add(e);
          }
        }
      }
    }
    add(payload['role']);
    final topRoles = payload['roles'];
    if (topRoles is List) {
      for (final e in topRoles) {
        add(e);
      }
    }
    // WordPress capability keys (role plugins sometimes only expose these).
    if (data is Map<String, dynamic>) {
      final user = data['user'];
      if (user is Map<String, dynamic>) {
        final caps = user['capabilities'];
        if (caps is Map) {
          for (final k in caps.keys) {
            add(k.toString());
          }
        }
      }
    }
    return out;
  }

  static String _metaKeysSample(Map<String, dynamic> c) {
    final meta = c['meta_data'];
    if (meta is! List) return '[]';
    final keys = <String>[];
    for (final e in meta.take(20)) {
      if (e is Map && e['key'] != null) keys.add(e['key'].toString());
    }
    return keys.toString();
  }

  /// Top-level `role`, plus `meta_data` when WC still reports generic `customer`.
  static String? _roleFromWooCustomerMap(Map<String, dynamic> c) {
    final top = c['role']?.toString();
    final metaHint = _roleHintFromWooMetaData(c);
    if (top == null || top.trim().isEmpty) return metaHint;
    if (metaHint == null) return top;
    final nt = _normalizeStoredRole(top);
    final nm = _normalizeStoredRole(metaHint);
    return _pickHigherPriorityRole(nt, nm) == nm ? metaHint : top;
  }

  static String? _roleHintFromWooMetaData(Map<String, dynamic> c) {
    final meta = c['meta_data'];
    if (meta is! List) return null;
    for (final e in meta) {
      if (e is! Map) continue;
      final key = (e['key'] as String?)?.toLowerCase() ?? '';
      final val = e['value'];
      final s = val is String
          ? val
          : (val is Map || val is List)
              ? jsonEncode(val)
              : val?.toString() ?? '';
      final sl = s.toLowerCase();
      if (key.contains('wholesale') || sl.contains('wholesale')) {
        return 'wholesale';
      }
      if (key.contains('dropship') || sl.contains('dropship')) {
        return 'dropshipping';
      }
      if (key.contains('retail') || key == 'account_type' || key.contains('b2b')) {
        if (sl.contains('wholesale')) return 'wholesale';
        if (sl.contains('dropship')) return 'dropshipping';
        if (sl.contains('retail')) return 'retailer';
      }
    }
    return null;
  }

  static int? _wpUserIdFromJwtPayload(Map<String, dynamic>? payload) {
    if (payload == null) return null;
    final data = payload['data'];
    if (data is Map<String, dynamic>) {
      final user = data['user'];
      if (user is Map<String, dynamic>) {
        final id = user['id'];
        if (id is int) return id;
        if (id is num) return id.toInt();
      }
    }
    return null;
  }

  /// Authenticated WP user lookup (`/wp-json/wp/v2/users/{id}?context=edit`).
  /// Requires the JWT auth plugin to allow this endpoint with Bearer token.
  Future<Map<String, dynamic>?> _fetchWpUserById(
    String token,
    int wpUserId,
  ) async {
    final url = Uri.parse('$kStoreBaseUrl/wp-json/wp/v2/users/$wpUserId')
        .replace(queryParameters: {'context': 'edit'});
    try {
      final response = await http
          .get(
            url,
            headers: {
              'Authorization': 'Bearer $token',
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (kDebugMode) {
        debugPrint(
          '[Auth] WP GET ${url.path}?context=edit → ${response.statusCode} '
          'body=${_truncateBody(response.body)}',
        );
      }

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) return decoded;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Auth] WP users/{id} error: $e');
    }
    return null;
  }

  static List<String> _extractRoleStringsFromWpUser(
    Map<String, dynamic> wpUser,
  ) {
    final out = <String>[];
    final roles = wpUser['roles'];
    if (roles is List) {
      for (final e in roles) {
        if (e != null) out.add(e.toString());
      }
    }
    final caps = wpUser['capabilities'];
    if (caps is Map) {
      for (final k in caps.keys) {
        out.add(k.toString());
      }
    }
    return out;
  }

  /// Look up WooCommerce customer by WP user ID extracted from JWT payload.
  /// Uses `Authorization: Bearer <user_jwt>` against wc/v3 — the JWT plugin
  /// authenticates the request so wp-cerber allows it through.
  Future<Map<String, dynamic>?> _fetchWooCustomerByJwt(
    String token,
    Map<String, dynamic>? jwtPayload,
  ) async {
    final uid = _wpUserIdFromJwtPayload(jwtPayload);
    if (uid == null) return null;

    // wc/v3/customers/{id} authenticated with the user's own JWT Bearer.
    // This tells wp-cerber the request comes from an authenticated WP user.
    final idUrl = Uri.parse('$kStoreBaseUrl/wp-json/wc/v3/customers/$uid');
    try {
      final response = await http.get(
        idUrl,
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 10));
      if (kDebugMode) {
        debugPrint(
          '[Auth] WC GET wc/v3/customers/$uid → ${response.statusCode} '
          'body=${_truncateBody(response.body)}',
        );
      }
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) return decoded;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Auth] WC customers/$uid error: $e');
    }
    return null;
  }

  static String _truncateBody(String body, [int max = 2000]) {
    if (body.length <= max) return body;
    return '${body.substring(0, max)}…';
  }

  /// Extract role-like strings from the `wp-json/jwt-auth/v1/token` response JSON.
  /// Some JWT configurations (filters) inject `roles`/`role` here, even if the
  /// roles are not present in the JWT payload itself.
  static List<String> _extractRoleStringsFromTokenResponseBody(
    Map<String, dynamic> tokenResponse,
  ) {
    final out = <String>[];

    void add(dynamic v) {
      if (v is String && v.trim().isNotEmpty) out.add(v.trim());
    }

    final roles = tokenResponse['roles'];
    if (roles is List) {
      for (final e in roles) {
        if (e != null) add(e.toString());
      }
    }

    final role = tokenResponse['role'];
    if (role != null) add(role);

    final user = tokenResponse['user'];
    if (user is Map<String, dynamic>) {
      final userRoles = user['roles'];
      if (userRoles is List) {
        for (final e in userRoles) {
          if (e != null) add(e.toString());
        }
      }
      final userRole = user['role'];
      if (userRole != null) add(userRole);
    }

    return out;
  }

  static int _roleRank(String normalized) {
    switch (normalized) {
      case 'wholesale':
        return 4;
      case 'dropshipping':
        return 3;
      case 'retailer':
        return 2;
      case 'customers':
        return 1;
      default:
        return 0;
    }
  }

  /// Prefer wholesale / trade roles over generic `customer` when JWT lists multiple.
  static String _pickHigherPriorityRole(String a, String b) {
    return _roleRank(a) >= _roleRank(b) ? a : b;
  }

  static String _normalizeStoredRole(String raw) {
    final r = raw.toLowerCase().trim();
    if (r.isEmpty) return 'customers';
    if (r.contains('wholesale')) return 'wholesale';
    if (r.contains('dropship')) return 'dropshipping';
    if (r == 'retailer' ||
        (r.contains('retail') && !r.contains('wholesale'))) {
      return 'retailer';
    }
    if (r == 'customer' ||
        r == 'customers' ||
        r == 'subscriber' ||
        r == 'shop_manager' ||
        r == 'editor' ||
        r == 'author' ||
        r == 'contributor' ||
        r == 'administrator') {
      if (r == 'administrator' || r == 'shop_manager') {
        return 'customers';
      }
      return 'customers';
    }
    return r;
  }

  /// Look up a WooCommerce customer by email using user's JWT token.
  /// Requires the current user's JWT to authenticate — no API key needed.
  Future<Map<String, dynamic>?> _fetchWooCustomerByEmail(String email) async {
    // Prefer the current user's session token; fall back to site-level JWT from .env.
    final token = (jwtToken?.isNotEmpty == true ? jwtToken : null) ?? kSiteJwtToken;
    if (token.isEmpty) {
      if (kDebugMode) {
        debugPrint('[Auth] WC customers?email= skipped: no JWT token available');
      }
      return null;
    }

    // wc/v3/customers?email= authenticated with JWT Bearer.
    final url = Uri.parse('$kStoreBaseUrl/wp-json/wc/v3/customers')
        .replace(queryParameters: {'email': email, 'context': 'edit'});

    try {
      final response = await http.get(
        url,
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 10));

      if (kDebugMode) {
        debugPrint(
          '[Auth] WC GET wc/v3/customers?email= → ${response.statusCode} '
          'body=${_truncateBody(response.body)}',
        );
      }

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        if (body is List && body.isNotEmpty) {
          return body.first as Map<String, dynamic>;
        }
        // Some setups return a single object if exactly one match
        if (body is Map<String, dynamic> && body.containsKey('id')) {
          return body;
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Auth] WC customers?email= error: $e');
    }
    return null;
  }

  /// Register a new WooCommerce customer via wc/v3/customers.
  /// Uses the site-level JWT token from .env as Bearer auth so wp-cerber
  /// allows the unauthenticated-user registration call through.
  Future<AuthResult> _registerWooCustomer({
    required String username,
    required String email,
    required String password,
    String? firstName,
    String role = 'customers',
    String? phone,
    String? abn,
    String? websiteUrl,
  }) async {
    // Use site JWT as primary Bearer auth; add Basic Auth as secondary credential
    // so WooCommerce validates the consumer key/secret for write access.
    final siteJwt = kSiteJwtToken;
    final hasKeys = kWooKey.isNotEmpty && kWooSecret.isNotEmpty;
    final basicAuth = hasKeys
        ? 'Basic ${base64Encode(utf8.encode('$kWooKey:$kWooSecret'))}'
        : null;
    final url = Uri.parse('$kStoreBaseUrl/wp-json/wc/v3/customers');

    // Build meta_data array for extra business fields
    final metaData = <Map<String, String>>[];
    if (abn != null && abn.isNotEmpty) {
      metaData.add({'key': 'abn', 'value': abn});
    }
    if (phone != null && phone.isNotEmpty) {
      metaData.add({'key': 'phone', 'value': phone});
    }
    if (websiteUrl != null && websiteUrl.isNotEmpty) {
      metaData.add({'key': 'website_url', 'value': websiteUrl});
    }

    try {
      final body = <String, dynamic>{
        'username': username.trim(),
        'email': email.trim(),
        'password': password,
        'first_name': firstName?.trim() ?? '',
        'role': role,
      };
      if (metaData.isNotEmpty) {
        body['meta_data'] = metaData;
      }

      // Build auth headers: prefer site JWT bearer; fall back to basic key/secret.
      final headers = <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };
      if (siteJwt.isNotEmpty) {
        headers['Authorization'] = 'Bearer $siteJwt';
      } else if (basicAuth != null) {
        headers['Authorization'] = basicAuth;
      }

      final response = await http.post(
        url,
        headers: headers,
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 15));

      final data = jsonDecode(response.body);

      if (response.statusCode == 201) {
        final customerId = data['id'] as int?;

        // Auto-login after registration to get JWT token
        String? token;
        try {
          final loginResult = await _loginWordPress(email: email, password: password);
          if (loginResult.isSuccess) {
            token = loginResult.session?.token;
          }
        } catch (_) {}

        final display = (firstName != null && firstName.trim().isNotEmpty)
            ? firstName.trim()
            : username.trim();
        return AuthResult.success(UserSession(
          email: email.trim(),
          displayName: display,
          role: role,
          token: token,
          customerId: customerId,
        ));
      } else {
        final msg = data['message'] ?? 'Registration failed.';
        final cleanMsg = msg.toString().replaceAll(RegExp(r'<[^>]*>'), '');
        return AuthResult.failure(sanitizeAuthApiMessage(cleanMsg));
      }
    } catch (e, st) {
      debugPrint('Auth registration error: $e\n$st');
      return AuthResult.failure(sanitizeAuthApiMessage(e.toString()));
    }
  }

  Future<void> _persist({
    required String email,
    required String name,
    required String role,
    String? token,
    int? customerId,
  }) async {
    await _prefs?.remove(_guestBrowseKey);
    await _prefs?.setString(_emailKey, email);
    await _prefs?.setString(_nameKey, name);
    await _prefs?.setString(_roleKey, role);
    await _prefs?.setBool(_loggedInKey, true);
    if (token != null) {
      await _prefs?.setString(_tokenKey, token);
    }
    if (customerId != null) {
      await _prefs?.setInt(_customerIdKey, customerId);
    }
    _sessionController.add(UserSession(
      email: email,
      displayName: name,
      role: role,
      token: token,
      customerId: customerId,
    ));
    notifyListeners();
  }
}

// ── Value objects ─────────────────────────────────────────────────────────────

class UserSession {
  final String email;
  final String displayName;
  final String role;
  final String? token;
  final int? customerId;
  const UserSession({
    required this.email,
    required this.displayName,
    this.role = 'customers',
    this.token,
    this.customerId,
  });
}

class AuthResult {
  final bool isSuccess;
  final String? errorMessage;
  final UserSession? session;

  const AuthResult._({required this.isSuccess, this.errorMessage, this.session});

  factory AuthResult.success(UserSession session) =>
      AuthResult._(isSuccess: true, session: session);

  factory AuthResult.failure(String message) =>
      AuthResult._(isSuccess: false, errorMessage: message);
}
