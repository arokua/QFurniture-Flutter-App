/// Maps catalogue codes (e.g. P001) to WooCommerce product ids when the API
/// leaves SKU empty or uses numeric ids only — keeps search working for known lines.
const Map<String, int> kProductSkuCodeToId = {
  'P001': 50159,
  'P002': 50268,
  'P003': 50278,
  'P004': 50324,
  'P005': 50337,
  'P006': 50355,
  'P007': 50366,
  'P008': 50370,
};
