/// Tunables for the crash-safe checkout attempt engine.
class CheckoutEngineConfig {
  CheckoutEngineConfig._();

  /// How long an outstanding attempt must have been dispatched before
  /// "the server does not have this order" is believed.
  ///
  /// Without a grace window, reconciliation racing WooCommerce finishing its
  /// order write would declare a perfectly good order failed.
  static const Duration reconcileGrace = Duration(seconds: 90);

  /// Hard ceiling on server lookups for one attempt, so a record can never sit
  /// in `unknown` forever probing on every resume.
  static const int maxLookupAttempts = 8;

  /// When an attempt has been unresolvable for this long, it stops blocking
  /// new checkouts.
  ///
  /// Without this, a customer whose order could never be confirmed — because
  /// the store stayed unreachable — would be permanently unable to order
  /// again, since an outstanding attempt is the duplicate guard. Releasing it
  /// is paired with a message telling them to check their order history first,
  /// which is honest about what the app does and does not know.
  static const Duration attemptStaleAfter = Duration(hours: 6);

  /// How long the checkout barrier waits for queued cart mutations to settle
  /// before refusing to submit.
  static const Duration drainTimeout = Duration(seconds: 12);
}
