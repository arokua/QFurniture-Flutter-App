import 'package:flutter_test/flutter_test.dart';
import 'package:Qtoys/services/app_log.dart';

void main() {
  setUp(() {
    AppLog.clearForTest();
    AppLog.configure(appVersion: '1.2.3');
    AppLog.setRole(null);
  });

  String lastLine() => AppLog.recent.last;

  group('redaction by key', () {
    test('a password is never recorded, whatever the field is called', () {
      AppLog.event('auth.change', fields: {
        'password': 'Trumpet9Walrus',
        'current_password': 'hunter2',
        'new_password': 'hunter3',
      });

      final line = lastLine();
      expect(line, contains('password=***'));
      expect(line, contains('current_password=***'));
      expect(line, contains('new_password=***'));
      expect(line, isNot(contains('Trumpet9Walrus')));
      expect(line, isNot(contains('hunter2')));
      expect(line, isNot(contains('hunter3')));
    });

    test('session material is redacted across its many spellings', () {
      AppLog.event('cart.sync', fields: {
        'Authorization': 'Bearer abc.def.ghi',
        'Cart-Token': 'ct_12345',
        'set-cookie': 'wordpress_logged_in=xyz',
        'X-WC-Store-API-Nonce': 'n0nc3',
        'jwt': 'eyJhbGciOiJIUzI1NiJ9.body.sig',
        'reset_code': '123456',
      });

      final line = lastLine();
      for (final leaked in [
        'abc.def.ghi',
        'ct_12345',
        'wordpress_logged_in',
        'n0nc3',
        'eyJhbGciOiJIUzI1NiJ9',
        '123456',
      ]) {
        expect(line, isNot(contains(leaked)), reason: '$leaked leaked');
      }
    });
  });

  group('redaction by value shape', () {
    test('a JWT quoted inside an innocuous field is still scrubbed', () {
      // The realistic leak: an error string that happens to quote a header.
      AppLog.event('auth.validate', fields: {
        'error': 'rejected token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig here',
      });

      final line = lastLine();
      expect(line, isNot(contains('eyJhbGciOiJIUzI1NiJ9')));
      expect(line, contains('***'));
    });

    test('a bearer credential in free text is scrubbed', () {
      AppLog.event('http.fail', fields: {
        'detail': 'sent Bearer sk-live-9f8a7b6c5d4e as auth',
      });

      final line = lastLine();
      expect(line, isNot(contains('sk-live-9f8a7b6c5d4e')));
      expect(line, contains('Bearer ***'));
    });

    test('an oversized value is truncated so one event cannot flood the log',
        () {
      AppLog.event('catalog.load', fields: {'body': 'x' * 5000});
      expect(lastLine().length, lessThan(600));
    });
  });

  group('retention', () {
    test('the buffer is bounded and keeps the newest events', () {
      for (var i = 0; i < 500; i++) {
        AppLog.event('tick', fields: {'i': i});
      }

      expect(AppLog.recent, hasLength(200));
      expect(AppLog.recent.last, contains('i=499'));
      expect(AppLog.recent.first, contains('i=300'));
    });
  });

  group('correlation', () {
    test('the header id is the id that appears in the emitted event', () {
      final op = AppLog.begin('cart.setQuantity');
      final headerId = op.headers[AppLog.correlationHeader];
      op.end(result: LogResult.ok);

      expect(headerId, isNotNull);
      expect(lastLine(), contains('cid=$headerId'));
    });

    test('the correlation header carries no credential', () {
      final op = AppLog.begin('cart.fetch');
      expect(op.headers.keys, ['X-Qtoys-Request-Id']);
      op.end();
    });

    test('ending twice does not emit a second, longer event', () {
      final op = AppLog.begin('cart.fetch');
      op.end(result: LogResult.ok);
      final after = AppLog.recent.length;
      op.end(result: LogResult.permanent);

      expect(AppLog.recent, hasLength(after));
      expect(lastLine(), contains('result=ok'));
    });
  });

  group('context', () {
    test('every event carries version, platform and anonymous session', () {
      AppLog.event('boot');
      final line = lastLine();
      expect(line, contains('ver=1.2.3'));
      expect(line, contains('plat='));
      expect(line, contains('sid='));
    });

    test('role is included when known and omitted when not', () {
      AppLog.event('boot');
      expect(lastLine(), isNot(contains('role=')));

      AppLog.setRole('wholesale');
      AppLog.event('boot');
      expect(lastLine(), contains('role=wholesale'));
    });

    test('fields added mid-operation reach the emitted event', () {
      final op = AppLog.begin('cart.pump');
      op.add('queueDepth', 4);
      op.add('localSeq', 17);
      op.end(result: LogResult.transient, httpStatus: 503);

      final line = lastLine();
      expect(line, contains('queueDepth=4'));
      expect(line, contains('localSeq=17'));
      expect(line, contains('status=503'));
      expect(line, contains('result=transient'));
    });
  });
}
