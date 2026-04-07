/// Maps catalogue codes (e.g. P001) to WooCommerce product ids when the API
/// leaves SKU empty or uses numeric ids only — keeps search working for known lines.
const Map<String, int> kProductSkuCodeToId = {
  'p001': 50159,
  'p002': 50268,
  'p003': 50278,
  'p004': 50324,
  'p005': 50337,
  'p006': 50355,
  'p007': 50366,
  'p008': 50370,
};
