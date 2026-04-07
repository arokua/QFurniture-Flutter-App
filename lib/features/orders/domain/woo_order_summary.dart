/// One order row from WooCommerce REST API `GET /wc/v3/orders`.
class WooOrderSummary {
  const WooOrderSummary({
    required this.id,
    required this.number,
    required this.status,
    required this.dateCreated,
    required this.total,
    required this.currency,
  });

  final int id;
  final String number;
  final String status;
  final DateTime dateCreated;
  final String total;
  final String currency;

  factory WooOrderSummary.fromJson(Map<String, dynamic> j) {
    final idVal = j['id'];
    final id = idVal is int ? idVal : int.tryParse(idVal?.toString() ?? '') ?? 0;
    final created = j['date_created']?.toString() ?? '';
    return WooOrderSummary(
      id: id,
      number: j['number']?.toString() ?? '$id',
      status: (j['status'] ?? '').toString(),
      dateCreated: DateTime.tryParse(created) ?? DateTime.fromMillisecondsSinceEpoch(0),
      total: (j['total'] ?? '0').toString(),
      currency: (j['currency'] ?? 'AUD').toString(),
    );
  }

  String get statusLabel {
    if (status.isEmpty) return '—';
    return status.replaceAll('-', ' ').split(' ').map((w) {
      if (w.isEmpty) return w;
      return w[0].toUpperCase() + w.substring(1);
    }).join(' ');
  }
}
