import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────────
// AuthService
//
// Currently uses a SharedPreferences-backed guest/local session so the app
// compiles and runs WITHOUT any backend dependency.
//
// HOW TO UPGRADE TO SUPABASE
// ─────────────────────────────────────────────────────────────────────────────
// 1. Add to pubspec.yaml:
//      supabase_flutter: ^2.3.4
//
// 2. Replace the contents of init() with:
//      await Supabase.initialize(
//        url: 'https://<your-project>.supabase.co',
//        anonKey: '<your-anon-key>',
//      );
//      _client = Supabase.instance.client;
//      _sessionController.add(_client!.auth.currentSession);
//      _client!.auth.onAuthStateChange.listen((data) {
//        _sessionController.add(data.session);
//      });
//
// 3. Uncomment supabase_related methods below.
// ─────────────────────────────────────────────────────────────────────────────

/// Lightweight auth service.  Acts as a local session store today; swappable
/// for Supabase (or Firebase) without touching the rest of the app.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  static const _emailKey = 'qf_auth_email';
  static const _nameKey = 'qf_auth_name';
  static const _loggedInKey = 'qf_auth_loggedin';

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
      ));
    } else {
      _sessionController.add(null);
    }
  }

  // ── Session stream ───────────────────────────────────────────────────────

  /// Emits the current [UserSession] or null when signed out.
  Stream<UserSession?> get sessionStream => _sessionController.stream;

  UserSession? get currentSession {
    final loggedIn = _prefs?.getBool(_loggedInKey) ?? false;
    if (!loggedIn) return null;
    return UserSession(
      email: _prefs?.getString(_emailKey) ?? '',
      displayName: _prefs?.getString(_nameKey) ?? '',
    );
  }

  bool get isSignedIn => currentSession != null;

  // ── Auth operations ──────────────────────────────────────────────────────

  /// Sign in with email + password.
  /// Replace the body with Supabase: await _client!.auth.signInWithPassword(...)
  Future<AuthResult> signIn({
    required String email,
    required String password,
  }) async {
    // TODO: replace with real backend call
    await Future.delayed(const Duration(milliseconds: 600)); // simulate network
    if (email.isEmpty || !email.contains('@')) {
      return AuthResult.failure('Invalid email address.');
    }
    if (password.length < 6) {
      return AuthResult.failure('Password must be at least 6 characters.');
    }
    await _persist(email: email, name: email.split('@').first);
    return AuthResult.success(UserSession(
      email: email,
      displayName: email.split('@').first,
    ));
  }

  /// Register a new account.
  Future<AuthResult> signUp({
    required String email,
    required String password,
    String? displayName,
  }) async {
    await Future.delayed(const Duration(milliseconds: 800));
    if (email.isEmpty || !email.contains('@')) {
      return AuthResult.failure('Invalid email address.');
    }
    if (password.length < 6) {
      return AuthResult.failure('Password must be at least 6 characters.');
    }
    final name = displayName?.trim().isNotEmpty == true
        ? displayName!.trim()
        : email.split('@').first;
    await _persist(email: email, name: name);
    return AuthResult.success(UserSession(email: email, displayName: name));
  }

  /// Sign out
  Future<void> signOut() async {
    await _prefs?.remove(_emailKey);
    await _prefs?.remove(_nameKey);
    await _prefs?.setBool(_loggedInKey, false);
    _sessionController.add(null);
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  Future<void> _persist({required String email, required String name}) async {
    await _prefs?.setString(_emailKey, email);
    await _prefs?.setString(_nameKey, name);
    await _prefs?.setBool(_loggedInKey, true);
    _sessionController.add(UserSession(email: email, displayName: name));
  }
}

// ── Value objects ─────────────────────────────────────────────────────────────

class UserSession {
  final String email;
  final String displayName;
  const UserSession({required this.email, required this.displayName});
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
