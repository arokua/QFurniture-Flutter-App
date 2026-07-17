import 'package:flutter/material.dart';

import '../app_router.dart';

/// Non-blocking feedback after optimistic checkout (home may already be visible).
void showCheckoutFeedbackSnackBar(String message) {
  final ctx = rootNavigatorKey.currentContext;
  if (ctx == null) return;
  final messenger = ScaffoldMessenger.of(ctx);
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ),
  );
}
