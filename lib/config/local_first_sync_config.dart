import 'package:flutter/foundation.dart' show kDebugMode;

/// Local-first sync behaviour (cart + order history).
///
/// Principle: smooth UX first, UI second, backend synchrony third.
class LocalFirstSyncConfig {
  LocalFirstSyncConfig._();

  /// When `true`, surfaces sync badges in cart/order UI and emits verbose logs.
  /// Flip to `true` only for development and QA.
  static const bool showSyncStatusAndLogging = false;

  /// Gate for anything that exposes technical internals: raw exception text,
  /// response headers, session-presence flags, queue counters.
  ///
  /// Production builds show friendly copy only. Never render session material
  /// (JWTs, cookies, cart tokens, response headers) outside this gate.
  static bool get diagnosticsEnabled =>
      kDebugMode || showSyncStatusAndLogging;

  /// Background cart sync interval (signed-in users).
  static const Duration cartSyncInterval = Duration(minutes: 3);

  /// Background order history sync interval.
  static const Duration orderSyncInterval = Duration(minutes: 15);
}
