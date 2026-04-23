/// When store web pricing is wrong, use these AUD reference list prices (regular).
/// App applies sale as 10% off this amount ([Product.salePrice]).
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

/// SKUs starting with `P` (case-insensitive): prices are only shown to signed-in users.
bool skuRequiresLoginToViewPrice(String? sku) {
  final s = sku?.trim();
  if (s == null || s.isEmpty) return false;
  return s.toUpperCase().startsWith('P');
}
