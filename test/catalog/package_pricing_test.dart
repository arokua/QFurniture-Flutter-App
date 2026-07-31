import 'package:flutter_test/flutter_test.dart';
import 'package:Qtoys/features/catalog/domain/product_pricing_policy.dart';
import 'package:Qtoys/features/catalog/domain/role_pricing.dart';

/// Guards the `wholesale-only` package price override.
///
/// The override map is declared with `P00x` keys while the store has used
/// `P000x`. A strict string match meant the override never applied and packages
/// rendered with no price at all.
void main() {
  group('canonicalPackageSku', () {
    test('collapses leading-zero variance to one key', () {
      expect(canonicalPackageSku('P001'), 'P1');
      expect(canonicalPackageSku('P0001'), 'P1');
      expect(canonicalPackageSku('P00001'), 'P1');
      expect(canonicalPackageSku('P1'), 'P1');
    });

    test('is case and whitespace tolerant', () {
      expect(canonicalPackageSku('  p0001  '), 'P1');
      expect(canonicalPackageSku('p8'), 'P8');
    });

    test('keeps distinct package numbers distinct', () {
      expect(canonicalPackageSku('P0001'), isNot(canonicalPackageSku('P0002')));
      expect(canonicalPackageSku('P0010'), 'P10');
      expect(canonicalPackageSku('P0010'), isNot(canonicalPackageSku('P001')));
    });

    test('leaves non-package SKUs alone', () {
      expect(canonicalPackageSku('816'), '816');
      expect(canonicalPackageSku('003'), '003');
      expect(canonicalPackageSku('PX-9'), 'PX-9');
      expect(canonicalPackageSku(null), isNull);
      expect(canonicalPackageSku('   '), isNull);
    });
  });

  group('backupRegularPriceForSku', () {
    test('resolves every declared package under both SKU spellings', () {
      for (final entry in kBackupRegularPriceAudBySku.entries) {
        final n = RegExp(r'\d+').firstMatch(entry.key)!.group(0)!;
        final short = 'P${int.parse(n)}';
        final padded3 = 'P${int.parse(n).toString().padLeft(3, '0')}';
        final padded4 = 'P${int.parse(n).toString().padLeft(4, '0')}';

        expect(backupRegularPriceForSku(short), entry.value,
            reason: '$short must resolve');
        expect(backupRegularPriceForSku(padded3), entry.value,
            reason: '$padded3 must resolve');
        expect(backupRegularPriceForSku(padded4), entry.value,
            reason: '$padded4 (the store spelling) must resolve');
      }
    });

    test('the P0001 spelling that previously missed now resolves', () {
      // Direct regression assertion for the reported bug.
      expect(backupRegularPriceForSku('P0001'), 722.6);
      expect(backupRegularPriceForSku('P0008'), 749.52);
    });

    test('returns null for catalogue SKUs and unknown packages', () {
      expect(backupRegularPriceForSku('816'), isNull);
      expect(backupRegularPriceForSku('003'), isNull);
      expect(backupRegularPriceForSku('P0099'), isNull);
      expect(backupRegularPriceForSku(null), isNull);
    });

    test('every declared package price is a positive AUD amount', () {
      for (final entry in kBackupRegularPriceAudBySku.entries) {
        expect(entry.value, greaterThan(0), reason: '${entry.key} price');
      }
    });
  });

  group('skuRequiresLoginToViewPrice', () {
    test('gates package SKUs regardless of spelling', () {
      expect(skuRequiresLoginToViewPrice('P001'), isTrue);
      expect(skuRequiresLoginToViewPrice('P0001'), isTrue);
      expect(skuRequiresLoginToViewPrice(' p0002 '), isTrue);
    });

    test('does not gate ordinary numeric catalogue SKUs', () {
      expect(skuRequiresLoginToViewPrice('816'), isFalse);
      expect(skuRequiresLoginToViewPrice('010 481 570'), isFalse);
      expect(skuRequiresLoginToViewPrice(null), isFalse);
      expect(skuRequiresLoginToViewPrice(''), isFalse);
    });
  });

  group('role multipliers applied to a package list price', () {
    // Sale is 10% off the reference list price (see _applyBackupPricingIfApplicable).
    const listPrice = 722.6;
    final salePrice = RolePricing.roundMoney(listPrice * 0.9);

    test('sale price derives from the list price', () {
      expect(salePrice, 650.34);
    });

    test('each role tier scales the package sale price', () {
      expect(RolePricing.roundMoney(salePrice * RolePricing.multiplierFor('customer')), 650.34);
      expect(RolePricing.roundMoney(salePrice * RolePricing.multiplierFor('wholesale')), 325.17);
      expect(RolePricing.roundMoney(salePrice * RolePricing.multiplierFor('dropshipping')), 357.69);
      expect(RolePricing.roundMoney(salePrice * RolePricing.multiplierFor('retailer')), 357.69);
      expect(RolePricing.roundMoney(salePrice * RolePricing.multiplierFor('administrator')), 487.76);
    });

    test('an unknown role falls back to full retail', () {
      expect(RolePricing.multiplierFor('not_a_role'), 1.0);
      expect(RolePricing.multiplierFor(null), 1.0);
    });
  });
}
