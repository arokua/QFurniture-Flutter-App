import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:http/http.dart' as http;

import '../../../config/store_config.dart';

/// Outcome of a password-reset call.
///
/// [retryAfter] is populated when the server rate-limits the caller, so the UI
/// can say how long to wait instead of showing a bare failure.
class PasswordResetResult {
  const PasswordResetResult({
    required this.ok,
    this.message,
    this.token,
    this.retryAfter,
  });

  final bool ok;

  /// Friendly, already-sanitised copy. Never a raw server string.
  final String? message;

  /// JWT returned by `confirm`, so a successful reset signs the user straight
  /// in rather than bouncing them back to a login form.
  final String? token;

  final Duration? retryAfter;
}

/// Client for the native password-reset endpoints.
///
/// Contract implemented by `wordpress/qtoys-password-reset.php`:
///
/// * `POST /wp-json/qtoys/v1/password-reset/request` `{email}`
///   Always answers 200 with a generic body, so the response cannot be used to
///   discover which email addresses have accounts.
/// * `POST /wp-json/qtoys/v1/password-reset/confirm` `{email, code, password}`
///   Returns `{token}` on success.
class PasswordResetApi {
  PasswordResetApi._();

  static final PasswordResetApi instance = PasswordResetApi._();

  static String get _base => '$kStoreBaseUrl/wp-json/qtoys/v1/password-reset';

  static const Duration _timeout = Duration(seconds: 20);

  /// Deliberately identical whatever the server says about the address, so the
  /// UI cannot leak account existence either.
  static const String _genericRequestMessage =
      'If that email has an account, we\'ve sent a 6-digit code to it.';

  Future<PasswordResetResult> requestCode({required String email}) async {
    try {
      final res = await http
          .post(
            Uri.parse('$_base/request'),
            headers: _headers,
            body: jsonEncode({'email': email.trim()}),
          )
          .timeout(_timeout);

      if (kDebugMode) debugPrint('[PasswordReset] request → ${res.statusCode}');

      if (res.statusCode == 429) {
        return PasswordResetResult(
          ok: false,
          message: 'Too many attempts. Please wait a moment and try again.',
          retryAfter: _retryAfter(res),
        );
      }
      if (res.statusCode == 200) {
        return const PasswordResetResult(
          ok: true,
          message: _genericRequestMessage,
        );
      }
      return PasswordResetResult(ok: false, message: _friendly(res));
    } catch (e) {
      if (kDebugMode) debugPrint('[PasswordReset] request error: $e');
      return const PasswordResetResult(ok: false, message: _offlineMessage);
    }
  }

  Future<PasswordResetResult> confirm({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    try {
      final res = await http
          .post(
            Uri.parse('$_base/confirm'),
            headers: _headers,
            body: jsonEncode({
              'email': email.trim(),
              'code': code.trim(),
              'password': newPassword,
            }),
          )
          .timeout(_timeout);

      if (kDebugMode) debugPrint('[PasswordReset] confirm → ${res.statusCode}');

      if (res.statusCode == 429) {
        return PasswordResetResult(
          ok: false,
          message: 'Too many attempts. Please wait a moment and try again.',
          retryAfter: _retryAfter(res),
        );
      }

      if (res.statusCode == 200) {
        final decoded = _decode(res);
        return PasswordResetResult(
          ok: true,
          token: decoded?['token']?.toString(),
        );
      }

      // The server answers with a single code for a bad or expired pair, so
      // the message cannot be used to tell which of the two was wrong.
      final code0 = _decode(res)?['code']?.toString() ?? '';
      if (code0 == 'qtoys_reset_invalid_code') {
        return const PasswordResetResult(
          ok: false,
          message: 'That code is incorrect or has expired. '
              'Request a new one and try again.',
        );
      }
      if (code0 == 'qtoys_reset_weak_password') {
        return const PasswordResetResult(
          ok: false,
          message: 'Please choose a stronger password.',
        );
      }
      return PasswordResetResult(ok: false, message: _friendly(res));
    } catch (e) {
      if (kDebugMode) debugPrint('[PasswordReset] confirm error: $e');
      return const PasswordResetResult(ok: false, message: _offlineMessage);
    }
  }

  static const Map<String, String> _headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'User-Agent': kAppUserAgent,
  };

  static const String _offlineMessage =
      "We couldn't reach the store. Check your connection and try again.";

  Map<String, dynamic>? _decode(http.Response res) {
    try {
      final decoded = jsonDecode(res.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Duration? _retryAfter(http.Response res) {
    final raw = res.headers['retry-after'];
    final seconds = int.tryParse(raw ?? '');
    return seconds == null ? null : Duration(seconds: seconds);
  }

  /// Never surfaces a raw server string: a 404 here means the plugin is not
  /// installed, which must not reach the user as "no route was found".
  String _friendly(http.Response res) {
    if (res.statusCode == 404) {
      return 'Password reset is unavailable right now. '
          'Please contact us and we\'ll help you straight away.';
    }
    return 'Something went wrong. Please try again in a moment.';
  }
}
