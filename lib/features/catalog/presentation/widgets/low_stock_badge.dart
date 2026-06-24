import 'package:flutter/material.dart';

import '../../domain/product.dart';

/// Compact yellow indicator for low-stock products (tooltip explains meaning).
class LowStockBadge extends StatelessWidget {
  const LowStockBadge({
    super.key,
    this.compact = true,
    this.showLabel = false,
  });

  /// Dot-only (grid/list thumbnails). Set [showLabel] for slightly more context.
  final bool compact;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final tooltip = 'Low stock — only ${kLowStockThreshold} or fewer left';

    if (showLabel) {
      return Tooltip(
        message: tooltip,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.amber.shade600,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              const Text(
                'Low',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Tooltip(
      message: tooltip,
      preferBelow: false,
      child: Container(
        width: compact ? 11 : 14,
        height: compact ? 11 : 14,
        decoration: BoxDecoration(
          color: Colors.amber.shade600,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
      ),
    );
  }
}
