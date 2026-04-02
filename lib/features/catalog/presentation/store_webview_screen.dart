import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../../config/store_cart_api_service.dart';
import '../../../config/store_config.dart';
import '../../../services/auth_service.dart';
import '../../cart/data/cart_provider.dart';

/// In-app WebView for the store (qtoys.com.au). Preserves session/cookies
/// in this WebView context so add_to_cart and checkout work.
/// On close, syncs cookies back to StoreCartApiService and refreshes the
/// mobile cart from remote state.
class StoreWebViewScreen extends ConsumerStatefulWidget {
  const StoreWebViewScreen({
    super.key,
    required this.initialUrl,
    this.attemptWebLogin = false,
  });

  final String initialUrl;
  final bool attemptWebLogin;

  /// Opens the store URL: in-app WebView on mobile/desktop, new tab on web.
  static void push(
    BuildContext context,
    String url, {
    bool attemptWebLogin = false,
  }) {
    if (kIsWeb) {
      launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
      return;
    }
    context.push(
      Uri(path: '/store', queryParameters: {
        'url': url,
        if (attemptWebLogin) 'autologin': '1',
      }).toString(),
    );
  }

  @override
  ConsumerState<StoreWebViewScreen> createState() =>
      _StoreWebViewScreenState();
}

class _StoreWebViewScreenState extends ConsumerState<StoreWebViewScreen> {
  late final WebViewController _controller;
  final _cookieManager = WebViewCookieManager();
  bool _autoLoginSubmitted = false;
  bool _authBootstrapDone = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) return;

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {},
          onPageFinished: (_) async {
            if (!widget.attemptWebLogin) return;
            if (!_authBootstrapDone) {
              await _bootstrapWebSession();
              return;
            }
            if (!_autoLoginSubmitted) {
              await _submitWordPressLoginIfNeeded();
            }
          },
          onWebResourceError: (e) {
            debugPrint('StoreWebView error: ${e.description}');
          },
        ),
      );

    // Inject session cookie into WebView before loading, then load URL.
    _injectCookiesAndLoad();
  }

  /// Inject the StoreCartApiService session cookie into the WebView so the
  /// WooCommerce cart is shared between mobile and browser contexts.
  Future<void> _injectCookiesAndLoad() async {
    final rawCookie = StoreCartApiService.instance.cookie;
    if (rawCookie != null && rawCookie.isNotEmpty) {
      // Parse "name1=val1; name2=val2" into individual cookies
      final parts = rawCookie.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty);
      final storeUri = Uri.parse(kStoreBaseUrl);
      final domain = storeUri.host;

      for (final part in parts) {
        final eqIndex = part.indexOf('=');
        if (eqIndex <= 0) continue;
        final name = part.substring(0, eqIndex).trim();
        final value = part.substring(eqIndex + 1).trim();
        try {
          await _cookieManager.setCookie(
            WebViewCookie(
              name: name,
              value: value,
              domain: domain,
              path: '/',
            ),
          );
        } catch (e) {
          debugPrint('Cookie inject error: $e');
        }
      }
    }

    if (widget.attemptWebLogin) {
      // Load same-origin first, then establish session via custom JWT->cookie bridge.
      _controller.loadRequest(Uri.parse('$kStoreBaseUrl/'));
      return;
    }
    _controller.loadRequest(Uri.parse(widget.initialUrl));
  }

  Future<void> _bootstrapWebSession() async {
    _authBootstrapDone = true;
    final bridged = await _tryJwtCookieBridge();
    if (bridged) {
      await _controller.loadRequest(Uri.parse(widget.initialUrl));
      return;
    }
    // Fallback: WooCommerce my-account login (not wp-login.php).
    if (AuthService.instance.hasWebLoginCredentials) {
      final loginUrl = storeMyAccountLoginUrl(
        accountType: AuthService.instance.webAccountTypeForStoreLogin,
      );
      await _controller.loadRequest(
        Uri.parse(loginUrl).replace(
          queryParameters: {
            ...Uri.parse(loginUrl).queryParameters,
            'redirect_to': widget.initialUrl,
          },
        ),
      );
      _autoLoginSubmitted = false;
      return;
    }
    await _controller.loadRequest(Uri.parse(widget.initialUrl));
  }

  Future<bool> _tryJwtCookieBridge() async {
    final token = AuthService.instance.jwtToken;
    if (token == null || token.isEmpty) return false;
    final bridgePath = Uri.parse(jwtCookieBridgeUrl).path;
    final js = '''
(function() {
  return fetch('$bridgePath', {
    method: 'POST',
    credentials: 'include',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${_escapeJs(token)}'
    },
    body: JSON.stringify({ source: 'flutter_app_webview' })
  }).then(function(r) {
    return r.status >= 200 && r.status < 300 ? 'ok' : 'fail_' + r.status;
  }).catch(function() { return 'error'; });
})()
''';
    try {
      final result = await _controller.runJavaScriptReturningResult(js);
      final text = result.toString().replaceAll('"', '').trim();
      return text == 'ok';
    } catch (_) {
      return false;
    }
  }

  String _escapeJs(String s) => s
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll('\n', r'\n')
      .replaceAll('\r', '');

  Future<void> _submitWordPressLoginIfNeeded() async {
    if (_autoLoginSubmitted) return;
    final email = AuthService.instance.webLoginEmail;
    final password = AuthService.instance.webLoginPassword;
    if (email == null || password == null) return;
    _autoLoginSubmitted = true;
    final js = '''
(function() {
  var f = document.querySelector('form.woocommerce-form-login');
  if (!f) f = document.querySelector('form[action*="login"]');
  var u = document.querySelector('#username') || (f && f.querySelector('input[name="username"]'));
  var p = document.querySelector('#password') || (f && f.querySelector('input[name="password"]'));
  if (!u || !p || !f) return 'no-login-form';
  u.value = '${_escapeJs(email)}';
  p.value = '${_escapeJs(password)}';
  f.submit();
  return 'submitted';
})();
''';
    try {
      await _controller.runJavaScriptReturningResult(js);
    } catch (e) {
      debugPrint('WebView auto-login submit error: $e');
    }
  }

  /// Read cookies back from the WebView via JavaScript and update
  /// StoreCartApiService so the mobile app has the latest session.
  Future<void> _syncCookiesBack() async {
    try {
      final result = await _controller.runJavaScriptReturningResult('document.cookie');
      // result is a JSON-encoded string like '"name1=val1; name2=val2"'
      String cookieStr = result.toString();
      // Strip surrounding quotes if present
      if (cookieStr.startsWith('"') && cookieStr.endsWith('"')) {
        cookieStr = cookieStr.substring(1, cookieStr.length - 1);
      }
      if (cookieStr.isNotEmpty) {
        await StoreCartApiService.instance.setCookie(cookieStr);
      }
    } catch (e) {
      debugPrint('Cookie sync back error: $e');
    }
  }

  /// Same-origin fetch includes HttpOnly session cookies — updates app cart even when
  /// `document.cookie` cannot see the WooCommerce session cookie.
  Future<void> _pullCartJsonFromWebView() async {
    try {
      final result = await _controller.runJavaScriptReturningResult('''
(function() {
  return fetch('/wp-json/wc/store/v1/cart', {
    credentials: 'include',
    headers: { 'Accept': 'application/json' }
  }).then(function(r) { return r.text(); });
})()
''');
      String text = result.toString().trim();
      if (text.startsWith('"') && text.endsWith('"')) {
        try {
          text = jsonDecode(text) as String;
        } catch (_) {
          text = text.substring(1, text.length - 1).replaceAll(r'\"', '"');
        }
      }
      if (text.isEmpty || text == 'null') return;
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        await ref.read(cartProvider.notifier).applyStoreCartFromJson(decoded);
      }
    } catch (e) {
      debugPrint('WebView cart JSON pull error: $e');
    }
  }

  /// Sync cart + cookies after checkout/cart changes in the WebView.
  Future<void> _syncAfterWebView() async {
    await _pullCartJsonFromWebView();
    await _syncCookiesBack();
    await ref.read(cartProvider.notifier).refreshFromRemote();
  }

  /// Close handler: pull cart JSON (HttpOnly-safe), cookies, then server refresh.
  Future<void> _handleClose() async {
    await _syncAfterWebView();
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _syncAfterWebView();
        if (!context.mounted) return;
        context.pop();
      },
      child: Scaffold(
      appBar: AppBar(
        title: const Text('Store'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _handleClose,
          tooltip: 'Close',
        ),
      ),
      body: SafeArea(
        child: kIsWeb
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.open_in_new,
                        size: 64, color: Colors.grey),
                    const SizedBox(height: 16),
                    const Text('WebView not supported on web.'),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: () =>
                          launchUrl(Uri.parse(widget.initialUrl)),
                      child: const Text('Open in new tab'),
                    ),
                  ],
                ),
              )
            : WebViewWidget(controller: _controller),
      ),
    ),
    );
  }
}
