import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app_router.dart';
import '../../../config/store_cart_api_service.dart';
import '../../../services/auth_service.dart';
import '../../../services/woo_commerce_rest_api.dart';
import '../../../utils/money_format.dart';
import '../data/cart_provider.dart';
import '../data/store_cart_snapshot.dart';
import '../data/woo_cart_provider.dart';
import '../../orders/presentation/order_history_screen.dart';

enum WholesalePaymentMethod { bankDeposit, creditCardPhone }

/// Native wholesale checkout: order summary + payment choice + create order via WC REST.
class WholesaleCheckoutSection extends ConsumerStatefulWidget {
  const WholesaleCheckoutSection({
    super.key,
    required this.snapshot,
    required this.moqMet,
  });

  final StoreCartApiSnapshot snapshot;
  final bool moqMet;

  @override
  ConsumerState<WholesaleCheckoutSection> createState() =>
      _WholesaleCheckoutSectionState();
}

class _WholesaleCheckoutSectionState
    extends ConsumerState<WholesaleCheckoutSection> {
  WholesalePaymentMethod _payment = WholesalePaymentMethod.bankDeposit;
  bool _submitting = false;

  static const _gold = Color(0xFFC4A035);

  Future<void> _submitOrder() async {
    if (_submitting || !widget.moqMet) return;

    final session = AuthService.instance.currentSession;
    final token = session?.token;
    final customerId = session?.customerId ??
        await AuthService.instance.ensureCustomerIdForCurrentSession();
    if (token == null || token.isEmpty || customerId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in again to place your order.')),
      );
      return;
    }

    final billingEmail = await AuthService.instance.resolvedAccountEmail();

    final lines = widget.snapshot.lines
        .map((l) => (productId: l.productId, quantity: l.quantity))
        .where((e) => e.productId > 0 && e.quantity > 0)
        .toList();
    if (lines.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Your cart is empty.')),
      );
      return;
    }

    setState(() => _submitting = true);
    try {
      final payment = _payment == WholesalePaymentMethod.bankDeposit
          ? (method: 'bacs', title: 'Bank Deposit')
          : (method: 'cod', title: 'Credit card (phone)');

      final result = await WooCommerceRestApi.instance.createWholesaleOrder(
        jwt: token,
        customerId: customerId,
        lineItems: lines,
        paymentMethod: payment.method,
        paymentMethodTitle: payment.title,
        billingEmail: billingEmail,
      );

      if (!mounted) return;

      if (result.order == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.error ?? 'Could not create order.')),
        );
        return;
      }

      await StoreCartApiService.instance.clearCart();
      ref.read(cartProvider.notifier).clear();
      ref.invalidate(wooCartProvider);
      ref.invalidate(orderHistoryProvider);

      final order = result.order!;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Order placed'),
          content: Text(
            'Order #${order.number} has been submitted.\n\n'
            '${_payment == WholesalePaymentMethod.bankDeposit ? 'Please transfer payment using the bank details below.' : 'Our team will contact you regarding payment.'}',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                context.push(AppRoutes.orders);
              },
              child: const Text('View orders'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tv = widget.snapshot.totalsView;
    final taxDisplay = tv.formatMinor(tv.totalTaxMinor) ?? formatStorePrice(0);
    final totalDisplay =
        tv.formattedTotal ?? formatStorePrice(_fallbackTotal(widget.snapshot));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              _summaryRow(
                label: 'Shipping',
                value:
                    'Our sale team will send you an invoice including postage. '
                    'Please DO NOT pay for this invoice.',
                multiline: true,
              ),
              const Divider(height: 1),
              _summaryRow(label: 'Tax', value: taxDisplay, valueColor: _gold),
              const Divider(height: 1),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Total',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      totalDisplay,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: _gold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Payment method',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        RadioListTile<WholesalePaymentMethod>(
          contentPadding: EdgeInsets.zero,
          title: const Text('Bank Deposit'),
          value: WholesalePaymentMethod.bankDeposit,
          groupValue: _payment,
          onChanged:
              _submitting ? null : (v) => setState(() => _payment = v!),
        ),
        if (_payment == WholesalePaymentMethod.bankDeposit)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(left: 8, bottom: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              'Please transfer the payment to:\n'
              'Account name: Quins Group Pty Ltd\n'
              'BSB: 033100\n'
              'A/c no: 413524\n'
              'Westpac bank',
              style: TextStyle(height: 1.45, fontSize: 13),
            ),
          ),
        RadioListTile<WholesalePaymentMethod>(
          contentPadding: EdgeInsets.zero,
          title: const Text('Credit card'),
          value: WholesalePaymentMethod.creditCardPhone,
          groupValue: _payment,
          onChanged:
              _submitting ? null : (v) => setState(() => _payment = v!),
        ),
        if (_payment == WholesalePaymentMethod.creditCardPhone)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(left: 8, bottom: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              'Pay by credit card: please ring our office at +61 9318 0058 '
              'to pay by credit card. We accept Visa and Master Cards with no surcharge.',
              style: TextStyle(height: 1.45, fontSize: 13),
            ),
          ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: (_submitting || !widget.moqMet) ? null : _submitOrder,
            child: _submitting
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Proceed'),
          ),
        ),
      ],
    );
  }

  Widget _summaryRow({
    required String label,
    required String value,
    Color? valueColor,
    bool multiline = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: valueColor,
                height: multiline ? 1.4 : null,
                fontSize: multiline ? 13 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  double _fallbackTotal(StoreCartApiSnapshot snap) {
    var total = 0.0;
    for (final l in snap.lines) {
      final minor = l.lineTotalMinor ??
          (l.priceMinor != null ? l.priceMinor! * l.quantity : 0);
      var d = 1.0;
      for (var i = 0; i < l.minorUnit; i++) {
        d *= 10;
      }
      total += minor / d;
    }
    return total;
  }
}
