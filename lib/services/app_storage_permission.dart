import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:permission_handler/permission_handler.dart';

/// Ensures the app may read/write its on-device cache (order history JSON, etc.).
///
/// Files live in the app-private documents directory. Android 10+ does not require
/// a runtime grant for that path; we still request legacy storage on older OEMs.
class AppStoragePermission {
  AppStoragePermission._();

  static bool _requested = false;

  static Future<bool> ensureGranted() async {
    if (kIsWeb) return true;
    if (!Platform.isAndroid) return true;

    final status = await Permission.storage.status;
    if (status.isGranted || status.isLimited) return true;

    if (!_requested) {
      _requested = true;
      final result = await Permission.storage.request();
      if (result.isGranted || result.isLimited) return true;
    }

    // App-private documents still work when the user denies shared storage.
    return true;
  }
}
