import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import '../config/local_first_sync_config.dart';

/// Debug logging gated by [LocalFirstSyncConfig.showSyncStatusAndLogging].
void localSyncLog(String message) {
  if (!kDebugMode || !LocalFirstSyncConfig.showSyncStatusAndLogging) return;
  debugPrint('[LocalSync] $message');
}
