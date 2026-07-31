/// Local price overrides for the `wholesale-only` package products.
///
/// These packages are defined in WooCommerce in a way that leaves no fetchable
/// price on the Store API, so the list price has to live here. Two consequences
/// worth being explicit about:
///
///  * This map is **not authoritative** and **not protected**. Anything bundled
///    in an APK/IPA is extractable, so these values must never be the final
///    word at checkout — reconcile against the server before creating an order.
///  * Because `fetch_woocommerce_products.py` reads the *anonymous* Store API,
///    wholesale-only products never reach `assets/data/products.json`. The
///    offline catalogue therefore cannot contain these SKUs at all.
///
/// Keys are matched leniently — see [canonicalPackageSku]. Store SKUs have been
/// written both as `P001` and `P0001`; a strict string match silently failed and
/// the override never applied, which is why packages showed no price.
const Map<String, double> kBackupRegularPriceAudBySku = {
  'P001': 722.6,
  'P002': 1054.0,
  'P003': 878.20,
  'P004': 840.6,
  'P005': 1094.20,
  'P006': 902.4,
  'P007': 852.84,
  'P008': 749.52,
};

/// Normalises a package SKU so leading-zero variance cannot cause a miss.
///
/// `P001`, `P0001` and `p1` all canonicalise to `P1`. Non-package SKUs are
/// returned upper-cased and trimmed but otherwise untouched.
String? canonicalPackageSku(String? sku) {
  final trimmed = sku?.trim().toUpperCase();
  if (trimmed == null || trimmed.isEmpty) return null;
  final match = RegExp(r'^P0*(\d+)$').firstMatch(trimmed);
  if (match == null) return trimmed;
  return 'P${match.group(1)}';
}

/// Canonicalised view of [kBackupRegularPriceAudBySku], built once.
final Map<String, double> _canonicalBackupPrices = {
  for (final entry in kBackupRegularPriceAudBySku.entries)
    canonicalPackageSku(entry.key)!: entry.value,
};

/// Reference AUD list price for a package SKU, or `null` when not a package.
double? backupRegularPriceForSku(String? sku) {
  final key = canonicalPackageSku(sku);
  if (key == null) return null;
  return _canonicalBackupPrices[key];
}

/// SKUs starting with `P` (case-insensitive): prices are only shown to
/// signed-in users. Regular catalogue SKUs are numeric (`"816"`, `"003"`).
bool skuRequiresLoginToViewPrice(String? sku) {
  final s = sku?.trim();
  if (s == null || s.isEmpty) return false;
  return s.toUpperCase().startsWith('P');
}
