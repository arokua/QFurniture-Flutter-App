import 'package:flutter_test/flutter_test.dart';
import 'package:Qtoys/features/catalog/domain/product.dart';

/// Guards the currency-unit handling in the catalogue parser.
///
/// WooCommerce Store API amounts are integers in **minor units**:
/// `"price":"990"` with `currency_minor_unit: 2` means **$9.90**.
///
/// The parser used to guess by magnitude (`>= 1000 && whole => cents` for
/// products, `>= 100` for variants). Everything under $10.00 therefore rendered
/// at 100x — verified against the live store, "Wooden Spoon" (sku 585) is
/// `"price":"990"` and showed as $990.00.
void main() {
  group('resolveCurrencyMinorUnit', () {
    test('reads the nested Store API field', () {
      expect(
        resolveCurrencyMinorUnit({
          'prices': {'currency_minor_unit': 2}
        }),
        2,
      );
    });

    test('reads a root-level marker (regenerated catalogue)', () {
      expect(resolveCurrencyMinorUnit({'currency_minor_unit': 0}), 0);
    });

    test('accepts a string value', () {
      expect(
        resolveCurrencyMinorUnit({
          'prices': {'currency_minor_unit': '3'}
        }),
        3,
      );
    });

    test('defaults to 2 for the bundled catalogue, which has no marker', () {
      expect(resolveCurrencyMinorUnit({'price': 3990.0}), 2);
    });
  });

  group('parseMinorUnitPrice', () {
    test('converts Store API integer strings', () {
      expect(parseMinorUnitPrice('990', 2), 9.90);
      expect(parseMinorUnitPrice('3990', 2), 39.90);
      expect(parseMinorUnitPrice('17990', 2), 179.90);
      expect(parseMinorUnitPrice('100000', 2), 1000.00);
    });

    test('sub-USD10 amounts are no longer inflated 100x', () {
      // The exact regression. Every one of these used to pass straight through.
      expect(parseMinorUnitPrice('990', 2), 9.90);
      expect(parseMinorUnitPrice('900', 2), 9.00);
      expect(parseMinorUnitPrice('550', 2), 5.50);
      expect(parseMinorUnitPrice('300', 2), 3.00);
      expect(parseMinorUnitPrice('5', 2), 0.05);
    });

    test('converts whole numeric minor units (bundled catalogue shape)', () {
      expect(parseMinorUnitPrice(3990.0, 2), 39.90);
      expect(parseMinorUnitPrice(990.0, 2), 9.90);
      expect(parseMinorUnitPrice(1650, 2), 16.50);
    });

    test('passes through amounts already in major units', () {
      // A decimal point means the value was pre-converted.
      expect(parseMinorUnitPrice(39.9, 2), 39.9);
      expect(parseMinorUnitPrice('39.90', 2), 39.90);
      expect(parseMinorUnitPrice(9.9, 2), 9.9);
    });

    test('an exponent of 0 disables division', () {
      // What a regenerated products.json declares.
      expect(parseMinorUnitPrice(39.9, 0), 39.9);
      expect(parseMinorUnitPrice(45, 0), 45.0);
      expect(parseMinorUnitPrice('45', 0), 45.0);
    });

    test('handles zero, null and junk without throwing', () {
      expect(parseMinorUnitPrice(null, 2), 0.0);
      expect(parseMinorUnitPrice('', 2), 0.0);
      expect(parseMinorUnitPrice('   ', 2), 0.0);
      expect(parseMinorUnitPrice('abc', 2), 0.0);
      expect(parseMinorUnitPrice(0, 2), 0.0);
      expect(parseMinorUnitPrice(<String>[], 2), 0.0);
    });

    test('strips currency symbols and separators', () {
      expect(parseMinorUnitPrice(r'$39.90', 2), 39.90);
      expect(parseMinorUnitPrice('1,650', 2), 16.50);
    });
  });

  group('Product.fromJson end-to-end', () {
    test('live Store API shape for Wooden Spoon resolves to 9.90 dollars', () {
      final p = Product.fromJson({
        'id': 14854,
        'name': 'Wooden Spoon',
        'sku': '585',
        'prices': {
          'price': '990',
          'regular_price': '990',
          'sale_price': '990',
          'currency_minor_unit': 2,
          'currency_code': 'AUD',
        },
      });
      expect(p.price, 9.90);
      expect(p.regularPrice, 9.90);
      expect(p.currency, 'AUD');
    });

    test('live Store API shape for a 39.90 dollar product', () {
      final p = Product.fromJson({
        'id': 50745,
        'name': 'Montessori Amphibian Anatomy Puzzle',
        'sku': '816',
        'prices': {
          'price': '3990',
          'regular_price': '3990',
          'currency_minor_unit': 2,
        },
      });
      expect(p.price, 39.90);
    });

    test('bundled catalogue shape (raw minor units, no marker)', () {
      final p = Product.fromJson({
        'id': 1,
        'name': 'x',
        'sku': '719',
        'price': 990.0,
        'regularPrice': 990.0,
      });
      expect(p.price, 9.90);
    });

    test('regenerated catalogue shape (major units + exponent 0)', () {
      final p = Product.fromJson({
        'id': 1,
        'name': 'x',
        'sku': '719',
        'price': 45.0,
        'regularPrice': 45.0,
        'currency_minor_unit': 0,
      });
      expect(p.price, 45.0,
          reason: 'a whole-dollar price must not be divided again');
    });

    test('a zero price stays zero rather than becoming a stray amount', () {
      final p = Product.fromJson({'id': 1, 'name': 'x', 'price': 0.0});
      expect(p.price, 0.0);
    });
  });

  group('Variant.fromJson agrees with Product.fromJson', () {
    test('the same amount parses identically in both', () {
      final product = Product.fromJson({
        'id': 1,
        'name': 'x',
        'prices': {'price': '990', 'currency_minor_unit': 2},
      });
      final variant = Variant.fromJson({
        'sku': 'v1',
        'label': 'Small',
        'prices': {'price': '990', 'currency_minor_unit': 2},
      });
      expect(variant.price, product.price);
      expect(variant.price, 9.90);
    });

    test('variants below one dollar are no longer inflated', () {
      // The old variant threshold was >= 100, so 50 cents passed through as $50.
      final v = Variant.fromJson({
        'sku': 'v2',
        'label': 'Tiny',
        'prices': {'price': '50', 'currency_minor_unit': 2},
      });
      expect(v.price, 0.50);
    });
  });
}
