/// Tunables for the single-writer cart engine.
class CartEngineConfig {
  CartEngineConfig._();

  /// How long to wait after the last gesture on a line before dispatching it.
  /// Rapid stepper taps inside this window collapse into one network call.
  static const Duration coalesceWindow = Duration(milliseconds: 350);

  /// Backoff for transient failures. The last entry repeats.
  static const List<Duration> retryBackoff = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 30),
  ];

  /// Attempts before a mutation is parked as permanently failed.
  static const int maxAttempts = 6;

  /// Consecutive transient network failures before the queue pauses.
  static const int offlinePauseThreshold = 3;

  /// A checkout hold older than this is treated as leaked and auto-released,
  /// so a crashed or exception-skipped checkout cannot freeze the cart forever.
  static const Duration checkoutHoldTtl = Duration(minutes: 3);

  /// Backoff delay for [attempt], where attempt 0 is the first retry.
  static Duration backoffFor(int attempt) {
    if (attempt < 0) return retryBackoff.first;
    if (attempt >= retryBackoff.length) return retryBackoff.last;
    return retryBackoff[attempt];
  }
}
