import 'package:flutter/material.dart';

/// Qtoys app icon used in app bars and auth screens.
class AppBrandLogo extends StatelessWidget {
  const AppBrandLogo({
    super.key,
    this.height = 36,
    this.borderRadius = 8,
  });

  final double height;
  final double borderRadius;

  static const _assetPath = 'assets/data/QIcon2.png';

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Image.asset(
        _assetPath,
        height: height,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => Text(
          'Qtoys',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
      ),
    );
  }
}
