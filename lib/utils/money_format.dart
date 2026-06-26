/// Store-facing price label (no currency code prefix).
String formatStorePrice(double amount, {int decimals = 2}) {
  return '\$${amount.toStringAsFixed(decimals)}';
}
