import 'dart:async';

import 'package:flutter/material.dart';

import '../app_router.dart';
import '../features/orders/domain/woo_order_summary.dart';
import '../services/order_history_sync_service.dart';
import 'post_checkout_navigation.dart';

/// Brief full-screen confirmation after checkout, then navigate home.
class CheckoutConfirmation {
  CheckoutConfirmation._();

  static Future<void> showAndContinue({
    required BuildContext context,
    required String orderNumber,
    int? orderId,
    WooOrderSummary? order,
    String? total,
  }) async {
    if (order != null) {
      await OrderHistorySyncService.instance.writeThroughOrder(order);
    } else if (orderId != null && orderId > 0) {
      await OrderHistorySyncService.instance.writeThroughCheckout(
        orderId: orderId,
        orderNumber: orderNumber,
        total: total ?? '0',
      );
    }

    if (!context.mounted) {
      PostCheckoutNavigation.go();
      return;
    }

    final completer = Completer<void>();
    Timer? autoClose;

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, _, __) {
        autoClose = Timer(const Duration(milliseconds: 2600), () {
          if (!completer.isCompleted) {
            Navigator.of(ctx).pop();
            completer.complete();
          }
        });
        return SafeArea(
          child: Center(
            child: Material(
              color: Theme.of(ctx).colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              elevation: 8,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      size: 56,
                      color: Theme.of(ctx).colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Order submitted',
                      style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Order #$orderNumber',
                      style: Theme.of(ctx).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: () {
                        autoClose?.cancel();
                        Navigator.of(ctx).pop();
                        if (!completer.isCompleted) completer.complete();
                      },
                      child: const Text('Continue'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    await completer.future;
    PostCheckoutNavigation.go();
  }

  /// Uses the root navigator when the WebView route is being popped.
  static Future<void> showFromRoot({
    required String orderNumber,
    int? orderId,
    WooOrderSummary? order,
    String? total,
  }) async {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) {
      if (order != null) {
        await OrderHistorySyncService.instance.writeThroughOrder(order);
      } else if (orderId != null) {
        await OrderHistorySyncService.instance.writeThroughCheckout(
          orderId: orderId,
          orderNumber: orderNumber,
          total: total ?? '0',
        );
      }
      PostCheckoutNavigation.go();
      return;
    }
    await showAndContinue(
      context: ctx,
      orderNumber: orderNumber,
      orderId: orderId,
      order: order,
      total: total,
    );
  }
}
