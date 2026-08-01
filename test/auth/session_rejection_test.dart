import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:Qtoys/services/auth_service.dart';

/// Guards the classification that decides whether a user gets signed out.
///
/// Getting this wrong is not cosmetic: a 403 from Cloudflare was being read as
/// "WordPress rejected your token", which sent `ensureValidSession` down the
/// refresh path (an endpoint that does not exist on this site) and then into
/// `signOut()` — logging users out mid-session on every cart reconcile.
void main() {
  http.Response json(int status, Object body) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=UTF-8'},
      );

  group('a real WordPress rejection is honoured', () {
    test('jwt-auth invalid token', () {
      expect(
        AuthService.isWordPressAuthRejection(
          json(403, {'code': 'jwt_auth_invalid_token', 'message': 'Expired'}),
        ),
        isTrue,
      );
    });

    test('jwt-auth bad auth header', () {
      expect(
        AuthService.isWordPressAuthRejection(
          json(401, {'code': 'jwt_auth_bad_auth_header'}),
        ),
        isTrue,
      );
    });

    test('a core rest_ error code', () {
      expect(
        AuthService.isWordPressAuthRejection(
          json(401, {'code': 'rest_not_logged_in'}),
        ),
        isTrue,
      );
    });
  });

  group('an edge block is never treated as a token verdict', () {
    test('a Cloudflare HTML challenge page', () {
      final resp = http.Response(
        '<!DOCTYPE html><html><head><title>Access denied</title></head>'
        '<body>Cloudflare Ray ID: 8a1b2c3d</body></html>',
        403,
        headers: {'content-type': 'text/html; charset=UTF-8'},
      );
      expect(AuthService.isWordPressAuthRejection(resp), isFalse,
          reason: 'this is the exact response that was signing users out');
    });

    test('a 403 with no content type at all', () {
      expect(
        AuthService.isWordPressAuthRejection(http.Response('denied', 403)),
        isFalse,
      );
    });

    test('json that is not a WordPress error shape', () {
      expect(
        AuthService.isWordPressAuthRejection(json(403, {'error': 'blocked'})),
        isFalse,
      );
    });

    test('json whose code belongs to some other system', () {
      expect(
        AuthService.isWordPressAuthRejection(
          json(403, {'code': 'waf_rule_triggered'}),
        ),
        isFalse,
      );
    });

    test('a truncated or malformed json body', () {
      final resp = http.Response(
        '{"code":"jwt_auth_',
        403,
        headers: {'content-type': 'application/json'},
      );
      expect(AuthService.isWordPressAuthRejection(resp), isFalse);
    });

    test('a json array rather than an object', () {
      expect(
        AuthService.isWordPressAuthRejection(json(403, ['nope'])),
        isFalse,
      );
    });
  });
}
