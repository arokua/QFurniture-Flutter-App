import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, kIsWeb;
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
    this.addToCartItems,
  });

  final String initialUrl;
  final bool attemptWebLogin;
  final List<({int productId, int quantity})>? addToCartItems;

  /// Opens the store URL: in-app WebView on mobile/desktop, new tab on web.
  static void push(
    BuildContext context,
    String url, {
    bool attemptWebLogin = false,
    List<({int productId, int quantity})>? addToCartItems,
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
      extra: addToCartItems
          ?.map((e) => {'productId': e.productId, 'quantity': e.quantity})
          .toList(),
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

  late final List<({int productId, int quantity})> _addQueue;
  bool _addFlowStarted = false;
  bool _adding = false;
  int _addIndex = 0;
  final Map<int, int> _addRetryCountsByProductId = {};

  @override
  void initState() {
    super.initState();
    if (kIsWeb) return;

    _addQueue = widget.addToCartItems ?? const [];
    if (kDebugMode) {
      debugPrint(
        '[StoreWebView] init addQueueLen=${_addQueue.length} initialUrl=${widget.initialUrl}',
      );
    }

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {},
          onPageFinished: (String url) async {
            // If we are mid-add-to-cart sequence, just continue it.
            if (_adding) {
              if (kDebugMode) {
                debugPrint(
                  '[StoreWebView] add step finished; currentIndex=$_addIndex url=$url',
                );
              }
              _addIndex++;
              if (_addIndex < _addQueue.length) {
                final justAdded = _addQueue[_addIndex - 1];

                // Make sure WooCommerce has actually added the just-finished
                // line item before we navigate to the next add_to_cart URL.
                final hasItem = await _webViewCartHasItemFromCookies(
                  productId: justAdded.productId,
                  expectedQuantity: justAdded.quantity,
                );
                if (!hasItem) {
                  final prev = _addRetryCountsByProductId[justAdded.productId] ?? 0;
                  const maxRetries = 2;
                  if (prev < maxRetries) {
                    _addRetryCountsByProductId[justAdded.productId] = prev + 1;
                    if (kDebugMode) {
                      debugPrint(
                        '[StoreWebView] cart not updated for productId=${justAdded.productId}; retrying add_to_cart (retry=${prev + 1}/$maxRetries)',
                      );
                    }
                    // Roll back index so on the next pageFinished we increment
                    // back into the "next item" branch.
                    _addIndex--;
                    await _controller.loadRequest(
                      Uri.parse(
                        storeAddToCartUrl(
                          justAdded.productId,
                          quantity: justAdded.quantity,
                        ),
                      ),
                    );
                    return;
                  }
                  if (kDebugMode) {
                    debugPrint(
                      '[StoreWebView] cart verification failed for productId=${justAdded.productId}; giving up after $maxRetries retries',
                    );
                  }
                }
                final next = _addQueue[_addIndex];
                await _controller.loadRequest(
                  Uri.parse(
                    storeAddToCartUrl(
                      next.productId,
                      quantity: next.quantity,
                    ),
                  ),
                );
                if (kDebugMode) {
                  debugPrint(
                    '[StoreWebView] adding next productId=${next.productId} qty=${next.quantity}',
                  );
                }
              } else {
                _adding = false;
                if (kDebugMode) {
                  debugPrint('[StoreWebView] add queue done; loading final initialUrl');
                }
                // Final guard: if cart is still empty/missing the last item,
                // retry that last add URL a couple times before navigating
                // to checkout/cart.
                final lastAdded = _addQueue.lastOrNull;
                if (lastAdded != null) {
                  final hasLastItem = await _webViewCartHasItemFromCookies(
                    productId: lastAdded.productId,
                    expectedQuantity: lastAdded.quantity,
                  );
                  if (!hasLastItem) {
                    final prev = _addRetryCountsByProductId[lastAdded.productId] ?? 0;
                    const maxRetries = 2;
                    if (prev < maxRetries) {
                      _addRetryCountsByProductId[lastAdded.productId] = prev + 1;
                      if (kDebugMode) {
                        debugPrint(
                          '[StoreWebView] cart not updated for last productId=${lastAdded.productId}; retrying before checkout (retry=${prev + 1}/$maxRetries)',
                        );
                      }
                      _adding = true;
                      _addIndex--;
                      await _controller.loadRequest(
                        Uri.parse(
                          storeAddToCartUrl(
                            lastAdded.productId,
                            quantity: lastAdded.quantity,
                          ),
                        ),
                      );
                      return;
                    }
                  }
                }
                // Debug: confirm what WooCommerce thinks the cart contains
                // (using WebView cookies only) before loading checkout.
                await _debugPrintCartItemsCountFromWebViewCookies();
                await _controller.loadRequest(Uri.parse(widget.initialUrl));
              }
              return;
            }

            if (!widget.attemptWebLogin) return;
            if (!_authBootstrapDone) {
              await _bootstrapWebSession();
              return;
            }
            if (!_autoLoginSubmitted) {
              await _submitWordPressLoginIfNeeded();
              return;
            }
            if (!_addFlowStarted && _addQueue.isNotEmpty) {
              await _startAddToCartQueue();
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
  Future<void> _injectStoreCartCookies() async {
    final rawCookie = StoreCartApiService.instance.cookie;
    final cartToken = StoreCartApiService.instance.cartToken;
    if (kDebugMode) {
      debugPrint(
        '[StoreWebView] injectStoreCartCookies rawCookiePresent=${rawCookie != null && rawCookie.isNotEmpty} cartTokenPresent=${cartToken != null && cartToken.isNotEmpty}',
      );
    }
    if (rawCookie == null || rawCookie.isEmpty) return;

    // Parse "name1=val1; name2=val2" into individual cookies
    final parts =
        rawCookie.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty);
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

  /// Inject the StoreCartApiService session cookie into the WebView so the
  /// WooCommerce cart is shared between mobile and browser contexts.
  Future<void> _injectCookiesAndLoad() async {
    if (widget.attemptWebLogin) {
      // Share the app's WooCommerce session with the WebView so cart/checkout
      // sees the same lines as the Store API client (unless wholesale: local-only cart).
      if (!AuthService.instance.isWholesaleCartLocalOnly) {
        await _injectStoreCartCookies();
      }
      // JWT bridge runs on first pageFinished. Loading the storefront home first
      // then navigating to [initialUrl] caused unwanted redirects for my-account
      // and lost-password. With no add-to-cart queue, load the target URL directly.
      if (_addQueue.isNotEmpty) {
        _controller.loadRequest(Uri.parse('$kStoreBaseUrl/'));
      } else {
        _controller.loadRequest(Uri.parse(widget.initialUrl));
      }
      return;
    }
    await _injectStoreCartCookies();
    if (_addQueue.isNotEmpty) {
      await _startAddToCartQueue();
      return;
    }
    await _controller.loadRequest(Uri.parse(widget.initialUrl));
  }

  Future<void> _startAddToCartQueue() async {
    if (_addFlowStarted) return;
    _addFlowStarted = true;
    _addIndex = 0;
    _adding = true;

    final first = _addQueue[_addIndex];
    if (kDebugMode) {
      debugPrint(
        '[StoreWebView] starting addQueue: productId=${first.productId} qty=${first.quantity}',
      );
    }
    await _controller.loadRequest(
      Uri.parse(
        storeAddToCartUrl(first.productId, quantity: first.quantity),
      ),
    );
  }

  Future<void> _bootstrapWebSession() async {
    _authBootstrapDone = true;
    final bridged = await _tryJwtCookieBridge();
    if (bridged) {
      // Some backends Set-Cookie via JS fetch; give the browser a moment to
      // attach those cookies to subsequent requests.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      // JWT bridge sets WooCommerce cookies inside the WebView.
      if (_addQueue.isNotEmpty) {
        await _startAddToCartQueue();
      } else {
        await _controller.loadRequest(Uri.parse(widget.initialUrl));
      }
      return;
    }
    // Fallback: WooCommerce my-account login (not wp-login.php).
    if (AuthService.instance.hasWebLoginCredentials) {
      final loginUrl = storeMyAccountLoginUrl(
        accountType: AuthService.instance.webAccountTypeForStoreLogin,
      );
      final redirectTo = _addQueue.isNotEmpty ? storeCartUrl : widget.initialUrl;
      await _controller.loadRequest(
        Uri.parse(loginUrl).replace(
          queryParameters: {
            ...Uri.parse(loginUrl).queryParameters,
            'redirect_to': redirectTo,
          },
        ),
      );
      _autoLoginSubmitted = false;
      return;
    }
    if (_addQueue.isNotEmpty) {
      await _startAddToCartQueue();
    } else {
      await _controller.loadRequest(Uri.parse(widget.initialUrl));
    }
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
      final result = await _controller.runJavaScriptReturningResult(js);
      var text = result.toString().trim();
      if (text.startsWith('"') && text.endsWith('"') && text.length >= 2) {
        text = text.substring(1, text.length - 1);
      }
      if (text != 'submitted') {
        return;
      }
      _autoLoginSubmitted = true;
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

  /// Debug-only helper: fetch cart JSON via WooCommerce Store API using
  /// WebView cookies (no Store API Cart-Token header).
  Future<void> _debugPrintCartItemsCountFromWebViewCookies() async {
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
        // runJavaScriptReturningResult returns a JSON-encoded string.
        text = text.substring(1, text.length - 1);
        text = text.replaceAll(r'\"', '"');
      }
      if (text.isEmpty || text == 'null') return;

      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        final items = decoded['items'];
        final count = items is List ? items.length : null;
        debugPrint('[StoreWebView] cart (cookies-only) itemsCount=$count');
      }
    } catch (e) {
      debugPrint('WebView cart debug fetch error: $e');
    }
  }

  Future<bool> _webViewCartHasItemFromCookies({
    required int productId,
    required int expectedQuantity,
  }) async {
    try {
      // Give WooCommerce a moment to process the `?add_to_cart=...` request.
      await Future<void>.delayed(const Duration(milliseconds: 700));

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
        text = text.substring(1, text.length - 1);
        text = text.replaceAll(r'\"', '"');
      }
      if (text.isEmpty || text == 'null') return false;

      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return false;
      final items = decoded['items'];
      if (items is! List) return false;

      for (final e in items) {
        if (e is! Map<String, dynamic>) continue;
        final id = e['id'];
        final pid = id is int ? id : int.tryParse(id?.toString() ?? '');
        if (pid != productId) continue;

        final qRaw = e['quantity'];
        final q = qRaw is int ? qRaw : int.tryParse(qRaw?.toString() ?? '');
        if (q != null && q >= expectedQuantity) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Same-origin fetch includes HttpOnly session cookies — updates app cart even when
  /// `document.cookie` cannot see the WooCommerce session cookie.
  ///
  /// **Do not** send the app's `Cart-Token` header here: it can point at a different
  /// session than the browser cookie jar and return the wrong cart.
  Future<bool> _pullCartJsonFromWebView() async {
    final wholesaleLocal = AuthService.instance.isWholesaleCartLocalOnly;
    try {
      if (kDebugMode) {
        debugPrint(
          '[StoreWebView] pullCart: browser session only (no Cart-Token header)',
        );
      }
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
      if (text.isEmpty || text == 'null') return false;
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return false;
      if (decoded['items'] is! List) return false;
      if (!wholesaleLocal) {
        await StoreCartApiService.instance.absorbCartSessionFromCartJson(decoded);
      }
      await ref.read(cartProvider.notifier).applyStoreCartFromJson(decoded);
      return true;
    } catch (e) {
      debugPrint('WebView cart JSON pull error: $e');
      return false;
    }
  }

  /// Sync cart + cookies after checkout/cart changes in the WebView.
  Future<void> _syncAfterWebView() async {
    final wholesaleLocal = AuthService.instance.isWholesaleCartLocalOnly;
    if (wholesaleLocal) {
      await _pullCartJsonFromWebView();
      await _syncCookiesBack();
      ref.invalidate(storeCartFullProvider);
      return;
    }
    final pulledOk = await _pullCartJsonFromWebView();
    await _syncCookiesBack();
    if (!pulledOk) {
      await ref.read(cartProvider.notifier).refreshFromRemote();
    }
    ref.invalidate(storeCartFullProvider);
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
