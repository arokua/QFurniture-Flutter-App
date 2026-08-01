import 'package:flutter_test/flutter_test.dart';
import 'package:Qtoys/services/woo_commerce_rest_api.dart';

/// The rule that lets the app recognise an order it submitted but never saw
/// the response for. If this matching is wrong, reconciliation either misses a
/// real order (and the customer is told it failed) or matches the wrong one.
void main() {
  Map<String, dynamic> order(List<Map<String, dynamic>> meta) => {
        'id': 4821,
        'meta_data': meta,
      };

  test('matches the client order key in meta_data', () {
    final body = order([
      {'key': 'account_type', 'value': 'wholesale'},
      {'key': WooCommerceRestApi.clientOrderKeyMeta, 'value': 'qco_abc'},
    ]);
    expect(WooCommerceRestApi.orderCarriesClientKey(body, 'qco_abc'), isTrue);
  });

  test('does not match a different key value', () {
    final body = order([
      {'key': WooCommerceRestApi.clientOrderKeyMeta, 'value': 'qco_abc'},
    ]);
    expect(WooCommerceRestApi.orderCarriesClientKey(body, 'qco_xyz'), isFalse);
  });

  test('does not match the value under a different meta key', () {
    final body = order([
      {'key': 'some_other_key', 'value': 'qco_abc'},
    ]);
    expect(WooCommerceRestApi.orderCarriesClientKey(body, 'qco_abc'), isFalse);
  });

  test('an empty key never matches', () {
    final body = order([
      {'key': WooCommerceRestApi.clientOrderKeyMeta, 'value': ''},
    ]);
    expect(WooCommerceRestApi.orderCarriesClientKey(body, ''), isFalse,
        reason: 'an attempt with no key must not match an arbitrary order');
  });

  test('tolerates orders with missing or malformed meta_data', () {
    expect(
      WooCommerceRestApi.orderCarriesClientKey({'id': 1}, 'qco_abc'),
      isFalse,
    );
    expect(
      WooCommerceRestApi.orderCarriesClientKey(
        {'id': 1, 'meta_data': 'not-a-list'},
        'qco_abc',
      ),
      isFalse,
    );
    expect(
      WooCommerceRestApi.orderCarriesClientKey(
        {
          'id': 1,
          'meta_data': [null, 'junk', 42],
        },
        'qco_abc',
      ),
      isFalse,
    );
  });

  test('compares non-string meta values by their string form', () {
    final body = order([
      {'key': WooCommerceRestApi.clientOrderKeyMeta, 'value': 12345},
    ]);
    expect(WooCommerceRestApi.orderCarriesClientKey(body, '12345'), isTrue);
  });
}
