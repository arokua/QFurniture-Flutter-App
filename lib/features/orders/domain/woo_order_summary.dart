/// One line from WooCommerce order `line_items`.
class WooOrderLineItem {
  const WooOrderLineItem({
    required this.productId,
    required this.quantity,
    required this.name,
  });

  final int productId;
  final int quantity;
  final String name;

  Map<String, dynamic> toJson() => {
        'product_id': productId,
        'quantity': quantity,
        'name': name,
      };

  factory WooOrderLineItem.fromJson(Map<String, dynamic> j) {
    final pidRaw = j['product_id'];
    final productId =
        pidRaw is int ? pidRaw : int.tryParse(pidRaw?.toString() ?? '') ?? 0;
    final qRaw = j['quantity'];
    final quantity = qRaw is int
        ? qRaw
        : int.tryParse(qRaw?.toString() ?? '') ?? 0;
    return WooOrderLineItem(
      productId: productId,
      quantity: quantity,
      name: (j['name'] ?? '').toString(),
    );
  }
}

/// Local sync lifecycle for orders written before backend confirmation.
enum OrderSyncState { pending, synced, failed }

/// One order row from WooCommerce REST API `GET /wc/store/v1//orders`.
class WooOrderSummary {
  const WooOrderSummary({
    required this.id,
    required this.number,
    required this.status,
    required this.dateCreated,
    required this.total,
    required this.currency,
    this.customerId,
    this.lineItems = const [],
    this.syncState = OrderSyncState.synced,
    this.localRef,
    this.syncError,
  });

  final int id;
  final String number;
  final String status;
  final DateTime dateCreated;
  final String total;
  final String currency;
  final int? customerId;
  final List<WooOrderLineItem> lineItems;
  final OrderSyncState syncState;
  /// Temporary client id while [syncState] is [OrderSyncState.pending].
  final String? localRef;
  final String? syncError;

  bool get isPendingSync => syncState == OrderSyncState.pending;
  bool get isFailedSync => syncState == OrderSyncState.failed;

  Map<String, dynamic> toJson() => {
        'id': id,
        'number': number,
        'status': status,
        'date_created': dateCreated.toUtc().toIso8601String(),
        'total': total,
        'currency': currency,
        if (customerId != null) 'customer_id': customerId,
        'line_items': lineItems.map((e) => e.toJson()).toList(),
        'sync_state': syncState.name,
        if (localRef != null) 'local_ref': localRef,
        if (syncError != null) 'sync_error': syncError,
      };

  factory WooOrderSummary.fromJson(Map<String, dynamic> j) {
    final idVal = j['id'];
    final id = idVal is int ? idVal : int.tryParse(idVal?.toString() ?? '') ?? 0;
    final created = j['date_created']?.toString() ?? '';
    final cidRaw = j['customer_id'];
    final customerId = cidRaw == null
        ? null
        : (cidRaw is int
            ? cidRaw
            : int.tryParse(cidRaw.toString()));

    final lines = <WooOrderLineItem>[];
    final li = j['line_items'];
    if (li is List) {
      for (final e in li) {
        if (e is! Map<String, dynamic>) continue;
        final item = WooOrderLineItem.fromJson(e);
        if (item.productId > 0 && item.quantity > 0) {
          lines.add(item);
        }
      }
    }

    final syncRaw = (j['sync_state'] ?? 'synced').toString();
    final syncState = OrderSyncState.values.firstWhere(
      (s) => s.name == syncRaw,
      orElse: () => OrderSyncState.synced,
    );

    return WooOrderSummary(
      id: id,
      number: j['number']?.toString() ?? '$id',
      status: (j['status'] ?? '').toString(),
      dateCreated: DateTime.tryParse(created) ?? DateTime.fromMillisecondsSinceEpoch(0),
      total: (j['total'] ?? '0').toString(),
      currency: (j['currency'] ?? 'AUD').toString(),
      customerId: customerId,
      lineItems: lines,
      syncState: syncState,
      localRef: j['local_ref']?.toString(),
      syncError: j['sync_error']?.toString(),
    );
  }

  WooOrderSummary copyWith({
    int? id,
    String? number,
    String? status,
    DateTime? dateCreated,
    String? total,
    String? currency,
    int? customerId,
    List<WooOrderLineItem>? lineItems,
    OrderSyncState? syncState,
    String? localRef,
    String? syncError,
    bool clearLocalRef = false,
    bool clearSyncError = false,
  }) {
    return WooOrderSummary(
      id: id ?? this.id,
      number: number ?? this.number,
      status: status ?? this.status,
      dateCreated: dateCreated ?? this.dateCreated,
      total: total ?? this.total,
      currency: currency ?? this.currency,
      customerId: customerId ?? this.customerId,
      lineItems: lineItems ?? this.lineItems,
      syncState: syncState ?? this.syncState,
      localRef: clearLocalRef ? null : (localRef ?? this.localRef),
      syncError: clearSyncError ? null : (syncError ?? this.syncError),
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
