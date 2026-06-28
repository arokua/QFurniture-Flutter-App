import 'package:shared_preferences/shared_preferences.dart';

/// Where to send the user after checkout completes (native or store WebView).
enum PostCheckoutDestination {
  catalog,
  orderHistory,
  myAccountDashboard,
}

const _prefKey = 'qf_post_checkout_dest';
const _legacyPrefKey = 'qf_cramped_web_dest';

/// Persists post-checkout navigation (default: my-account dashboard).
class PostCheckoutDestinationPreference {
  PostCheckoutDestinationPreference._();

  static PostCheckoutDestination _cached =
      PostCheckoutDestination.myAccountDashboard;

  static PostCheckoutDestination get current => _cached;

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    var raw = prefs.getString(_prefKey);
    raw ??= prefs.getString(_legacyPrefKey);
    _cached = _parse(raw) ?? PostCheckoutDestination.myAccountDashboard;
  }

  static Future<void> set(PostCheckoutDestination value) async {
    _cached = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, value.name);
  }

  static PostCheckoutDestination? _parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    if (raw == 'myAccountOrders') return PostCheckoutDestination.catalog;
    for (final d in PostCheckoutDestination.values) {
      if (d.name == raw) return d;
    }
    return null;
  }

  static String label(PostCheckoutDestination d) {
    switch (d) {
      case PostCheckoutDestination.catalog:
        return 'App main screen (catalogue)';
      case PostCheckoutDestination.orderHistory:
        return 'Order history (in app)';
      case PostCheckoutDestination.myAccountDashboard:
        return 'My account dashboard (website)';
    }
  }
}
