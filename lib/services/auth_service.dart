import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/store_config.dart';

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

  SharedPreferences? _prefs;
  final _sessionController = StreamController<UserSession?>.broadcast();

  // ── Initialisation ───────────────────────────────────────────────────────

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    // Restore persisted session
    final isLoggedIn = _prefs!.getBool(_loggedInKey) ?? false;
    if (isLoggedIn) {
      _sessionController.add(UserSession(
        email: _prefs!.getString(_emailKey) ?? '',
        displayName: _prefs!.getString(_nameKey) ?? '',
        role: _prefs!.getString(_roleKey) ?? 'customers',
        token: _prefs!.getString(_tokenKey),
        customerId: _prefs!.getInt(_customerIdKey),
      ));
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

  bool get isSignedIn => currentSession != null;

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
    required String email,
    required String password,
    String? displayName,
    String role = 'customers',
    String? phone,
    String? abn,
    String? websiteUrl,
  }) async {
    final result = await _registerWooCustomer(
      email: email,
      password: password,
      displayName: displayName,
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

  /// Sign out
  Future<void> signOut() async {
    await _prefs?.remove(_emailKey);
    await _prefs?.remove(_nameKey);
    await _prefs?.remove(_roleKey);
    await _prefs?.remove(_tokenKey);
    await _prefs?.remove(_customerIdKey);
    await _prefs?.setBool(_loggedInKey, false);
    _sessionController.add(null);
    notifyListeners();
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
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': email,
          'password': password,
        }),
      ).timeout(const Duration(seconds: 15));

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200 && data['token'] != null) {
        final token = data['token'] as String;
        final userEmail = data['user_email'] as String? ?? email;
        final displayName = data['user_display_name'] as String? ?? email.split('@').first;

        // Fetch WC customer details to get role + customer ID
        String role = 'customers';
        int? customerId;
        try {
          final custResult = await _fetchWooCustomerByEmail(userEmail);
          if (custResult != null) {
            role = custResult['role'] ?? 'customers';
            customerId = custResult['id'] as int?;
          }
        } catch (_) {
          // Non-fatal: login still succeeds, defaults apply
        }

        await _persist(
          email: userEmail,
          name: displayName,
          role: role,
          token: token,
          customerId: customerId,
        );

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
        return AuthResult.failure(cleanMsg);
      }
    } catch (e) {
      return AuthResult.failure('Network error: $e');
    }
  }

  /// Look up a WooCommerce customer by email to get role + customer ID.
  Future<Map<String, dynamic>?> _fetchWooCustomerByEmail(String email) async {
    final basicAuth = 'Basic ${base64Encode(utf8.encode('$kWooKey:$kWooSecret'))}';
    final url = Uri.parse('$kStoreBaseUrl/wp-json/wc/v3/customers?email=$email');

    final response = await http.get(
      url,
      headers: {'Authorization': basicAuth},
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode == 200) {
      final list = jsonDecode(response.body) as List<dynamic>;
      if (list.isNotEmpty) {
        return list.first as Map<String, dynamic>;
      }
    }
    return null;
  }

  /// Register a new WooCommerce customer.
  Future<AuthResult> _registerWooCustomer({
    required String email,
    required String password,
    String? displayName,
    String role = 'customers',
    String? phone,
    String? abn,
    String? websiteUrl,
  }) async {
    final basicAuth = 'Basic ${base64Encode(utf8.encode('$kWooKey:$kWooSecret'))}';
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
        'email': email,
        'password': password,
        'first_name': displayName ?? '',
        'role': role,
      };
      if (metaData.isNotEmpty) {
        body['meta_data'] = metaData;
      }

      final response = await http.post(
        url,
        headers: {
          'Authorization': basicAuth,
          'Content-Type': 'application/json',
        },
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

        return AuthResult.success(UserSession(
          email: email,
          displayName: displayName ?? email.split('@').first,
          role: role,
          token: token,
          customerId: customerId,
        ));
      } else {
        final msg = data['message'] ?? 'Registration failed.';
        final cleanMsg = msg.toString().replaceAll(RegExp(r'<[^>]*>'), '');
        return AuthResult.failure(cleanMsg);
      }
    } catch (e) {
      return AuthResult.failure('Network error: $e');
    }
  }

  Future<void> _persist({
    required String email,
    required String name,
    required String role,
    String? token,
    int? customerId,
  }) async {
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
