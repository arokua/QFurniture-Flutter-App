import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show debugPrint, kDebugMode, kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../../config/store_cart_api_service.dart';
import '../../../config/store_config.dart';
import '../../../services/auth_service.dart';
import '../../cart/data/cart_provider.dart';
import '../../cart/data/woo_cart_provider.dart';
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
    this.useMobileLayout = false,
  });

  final String initialUrl;
  final bool attemptWebLogin;
  final List<({int productId, int quantity})>? addToCartItems;
  /// Request mobile viewport / user-agent (My account pages).
  final bool useMobileLayout;

  /// Opens the store URL: in-app WebView on mobile/desktop, new tab on web.
  static void push(
    BuildContext context,
    String url, {
    bool attemptWebLogin = false,
    List<({int productId, int quantity})>? addToCartItems,
    bool useMobileLayout = false,
  }) {
    if (kIsWeb) {
      launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
      return;
    }
    context.push(
      Uri(path: '/store', queryParameters: {
        'url': url,
        if (attemptWebLogin) 'autologin': '1',
        if (useMobileLayout) 'mobile': '1',
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
  static const _mobileSafariUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

  late final WebViewController _controller;
  final _cookieManager = WebViewCookieManager();
  bool _autoLoginSubmitted = false;
  bool _authBootstrapDone = false;
  /// iOS/WKWebView: JWT bridge via top-level navigation (Set-Cookie) instead of fetch only.
  bool _bridgeNavigationPending = false;
  String? _postBridgeTargetUrl;

  late final List<({int productId, int quantity})> _addQueue;
  bool _addFlowStarted = false;
  bool _adding = false;
  bool _finalTargetLoaded = false;
  int _addIndex = 0;

  /// Full-screen loading until the target store page has finished loading (checkout flow can take several seconds).
  bool _blockingOverlay = true;
  Timer? _overlayFailsafeTimer;
  final List<Timer> _loginPrefillTimers = [];

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

    _overlayFailsafeTimer = Timer(const Duration(seconds: 20), () {
      if (!mounted) return;
      setState(() => _blockingOverlay = false);
    });

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            if (!widget.attemptWebLogin) {
              return NavigationDecision.navigate;
            }
            final u = request.url.toLowerCase();
            // Cerber/Turnstile trap — never show wp-login in the WebView.
            if (u.contains('wp-login.php') || u.contains('/wp-admin')) {
              if (kDebugMode) {
                debugPrint(
                  '[StoreWebView] blocked navigation to $u — using storefront login',
                );
              }
              _redirectToStorefrontLogin();
              return NavigationDecision.prevent;
            }
            // Never leave the user on a REST JSON error page.
            if (u.contains('/wp-json/qtoys/v1/mobile-session') &&
                !u.contains('code=')) {
              if (kDebugMode) {
                debugPrint(
                  '[StoreWebView] blocked token/JSON bridge URL — retrying safe bridge',
                );
              }
              _retrySafeWebSessionBridge();
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageStarted: (_) {},
          onPageFinished: (String url) async {
            try {
              if (widget.useMobileLayout) {
                await _applyMobileLayoutEnhancements();
              }
              // If we are mid-add-to-cart sequence, just continue it.
              if (_adding) {
                if (kDebugMode) {
                  debugPrint(
                    '[StoreWebView] add step finished; _addIndex=$_addIndex url=$url',
                  );
                }

                // Small settle delay — let WooCommerce write its session cookie
                // before we navigate to the next item or to checkout.
                await Future<void>.delayed(const Duration(milliseconds: 800));

                _addIndex++;
                if (_addIndex < _addQueue.length) {
                  final next = _addQueue[_addIndex];
                  if (kDebugMode) {
                    debugPrint(
                      '[StoreWebView] adding next productId=${next.productId} qty=${next.quantity}',
                    );
                  }
                  await _controller.loadRequest(
                    Uri.parse(
                      storeAddToCartUrl(next.productId, quantity: next.quantity),
                    ),
                  );
                } else {
                  _adding = false;
                  if (!_finalTargetLoaded) {
                    _finalTargetLoaded = true;
                    if (kDebugMode) {
                      debugPrint('[StoreWebView] add queue done; loading ${widget.initialUrl}');
                    }
                    await _controller.loadRequest(Uri.parse(widget.initialUrl));
                  }
                }
                return;
              }

              if (!widget.attemptWebLogin) return;

              if (_bridgeNavigationPending) {
                // If the GET bridge fails it stays on /mobile-session (JSON error).
                // Do not return early — that left users stuck on the REST "backend" page.
                if (url.contains('mobile-session')) {
                  await Future<void>.delayed(const Duration(milliseconds: 400));
                  final liveUrl = await _controller.currentUrl() ?? url;
                  await _completeNavigationBridge(
                    liveUrl.contains('mobile-session') ? url : liveUrl,
                  );
                } else {
                  await _completeNavigationBridge(url);
                }
                return;
              }

              if (!_authBootstrapDone) {
                await _bootstrapWebSession();
                return;
              }
              if (!_autoLoginSubmitted) {
                if (await _verifyWebViewSession()) {
                  _autoLoginSubmitted = true;
                  _cancelLoginPrefillTimers();
                  return;
                }
                await _attemptLoginFormAssistance(url);
                if (!_addFlowStarted &&
                    _addQueue.isNotEmpty &&
                    _autoLoginSubmitted) {
                  await _startAddToCartQueue();
                }
                return;
              }
              if (!_addFlowStarted && _addQueue.isNotEmpty) {
                await _startAddToCartQueue();
                return;
              }
            } finally {
              if (mounted) _maybeDismissBlockingOverlay(url);
            }
          },
          onWebResourceError: (e) {
            debugPrint('StoreWebView error: ${e.description}');
          },
        ),
      );

    if (widget.useMobileLayout) {
      _controller.setUserAgent(_mobileSafariUserAgent);
    }

    // Inject session cookie into WebView before loading, then load URL.
    _injectCookiesAndLoad();
  }

  Future<void> _applyMobileLayoutEnhancements() async {
    try {
      await _controller.runJavaScript('''
(function() {
  var meta = document.querySelector('meta[name="viewport"]');
  if (!meta) {
    meta = document.createElement('meta');
    meta.name = 'viewport';
    document.head.appendChild(meta);
  }
  meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=5.0, viewport-fit=cover';

  var style = document.getElementById('qtoys-app-mobile-style');
  if (!style) {
    style = document.createElement('style');
    style.id = 'qtoys-app-mobile-style';
    document.head.appendChild(style);
  }
  style.textContent = `
    html { font-size: 18px !important; -webkit-text-size-adjust: 100%; }
    body, .site, .site-content, .content-area, .entry-content {
      max-width: 100% !important;
      width: 100% !important;
      box-sizing: border-box !important;
    }
    body.woocommerce-account .site-content,
    body.woocommerce-account .woocommerce {
      padding-left: 12px !important;
      padding-right: 12px !important;
    }
    .woocommerce-MyAccount-navigation,
    .woocommerce-MyAccount-content {
      width: 100% !important;
      max-width: 100% !important;
      float: none !important;
    }
    .woocommerce-MyAccount-navigation {
      margin-bottom: 1rem !important;
    }
    .woocommerce-MyAccount-navigation ul {
      display: flex !important;
      flex-wrap: wrap !important;
      gap: 8px !important;
      padding: 0 !important;
    }
    .woocommerce-MyAccount-navigation li {
      list-style: none !important;
      margin: 0 !important;
    }
    .woocommerce-MyAccount-navigation li a {
      display: block !important;
      font-size: 1rem !important;
      line-height: 1.35 !important;
      padding: 10px 14px !important;
      border-radius: 8px !important;
      background: #f5f5f5 !important;
    }
    .woocommerce-MyAccount-navigation-link.is-active a,
    .woocommerce-MyAccount-navigation-link--orders.is-active a {
      font-weight: 700 !important;
      background: #e8f5e9 !important;
    }
    .woocommerce-orders-table,
    .woocommerce-table--order-details,
    .shop_table {
      display: block !important;
      width: 100% !important;
      max-width: 100% !important;
      overflow-x: auto !important;
      font-size: 1rem !important;
    }
    .woocommerce-orders-table thead,
    .woocommerce-table--order-details thead {
      display: table-header-group !important;
    }
    .woocommerce-orders-table tbody,
    .woocommerce-table--order-details tbody {
      display: table-row-group !important;
    }
    .woocommerce-orders-table tr,
    .woocommerce-table--order-details tr {
      display: table-row !important;
    }
    .woocommerce-orders-table th,
    .woocommerce-orders-table td,
    .woocommerce-table--order-details th,
    .woocommerce-table--order-details td {
      font-size: 0.95rem !important;
      padding: 10px 8px !important;
      vertical-align: top !important;
      word-break: break-word !important;
    }
    .woocommerce-MyAccount-content p,
    .woocommerce-MyAccount-content li,
    .woocommerce-order-details,
    .woocommerce-customer-details {
      font-size: 1rem !important;
      line-height: 1.5 !important;
    }
    .woocommerce-button, .button, a.button {
      font-size: 1rem !important;
      padding: 12px 16px !important;
      min-height: 44px !important;
    }
    @media (max-width: 768px) {
      .woocommerce-orders-table thead { display: none !important; }
      .woocommerce-orders-table tr {
        display: block !important;
        margin-bottom: 12px !important;
        border: 1px solid #ddd !important;
        border-radius: 8px !important;
        padding: 8px !important;
      }
      .woocommerce-orders-table td {
        display: flex !important;
        justify-content: space-between !important;
        gap: 12px !important;
        border: none !important;
      }
      .woocommerce-orders-table td::before {
        content: attr(data-title);
        font-weight: 600 !important;
        flex: 0 0 40% !important;
      }
    }
  `;

  document.documentElement.style.width = '100%';
  document.body.style.width = '100%';
  document.body.style.margin = '0';

  var path = (window.location.pathname || '').toLowerCase();
  if (path.indexOf('/my-account/orders') >= 0 || path.indexOf('/view-order/') >= 0) {
    var ordersTab = document.querySelector('.woocommerce-MyAccount-navigation-link--orders');
    if (ordersTab) {
      ordersTab.classList.add('is-active');
      var link = ordersTab.querySelector('a');
      if (link) link.style.fontWeight = '700';
    }
    var content = document.querySelector('.woocommerce-MyAccount-content');
    if (content) content.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }
})();
''');
    } catch (_) {}
  }

  @override
  void dispose() {
    _overlayFailsafeTimer?.cancel();
    _cancelLoginPrefillTimers();
    super.dispose();
  }

  void _cancelLoginPrefillTimers() {
    for (final t in _loginPrefillTimers) {
      t.cancel();
    }
    _loginPrefillTimers.clear();
  }

  /// Cart checkout, My account, order history, etc. — login form or CF challenge.
  bool _urlLooksLikeStoreLogin(String url) {
    final parsed = Uri.tryParse(url);
    if (parsed == null) return false;
    final host = parsed.host.toLowerCase();
    final path = parsed.path.toLowerCase();
    if (host.contains('challenges.cloudflare')) return true;
    if (!host.contains('qtoys')) return false;
    if (path.contains('my-account')) {
      final action = parsed.queryParameters['action']?.toLowerCase();
      if (action == 'login' || path.contains('login')) return true;
    }
    if (path.contains('wp-login.php')) return true;
    return false;
  }

  Future<void> _attemptLoginFormAssistance(String pageUrl) async {
    if (!widget.attemptWebLogin || _autoLoginSubmitted) return;
    if (!AuthService.instance.hasWebLoginCredentials) return;

    final hasCaptcha = await _pageHasCaptchaChallenge();
    final hasForm = await _pageHasLoginForm();
    final onLoginUrl = _urlLooksLikeStoreLogin(pageUrl);

    if (!hasCaptcha && !hasForm && !onLoginUrl) return;

    await _prefillWooCommerceLoginCredentials();

    if (hasCaptcha || onLoginUrl) {
      _scheduleLoginPrefillRetries();
      if (hasCaptcha) return;
    }

    if (hasForm) {
      await _submitWooCommerceLoginIfNeeded();
    }
  }

  void _scheduleLoginPrefillRetries() {
    _cancelLoginPrefillTimers();
    for (final delayMs in [600, 1400, 2800, 4500]) {
      _loginPrefillTimers.add(
        Timer(Duration(milliseconds: delayMs), () async {
          if (!mounted || _autoLoginSubmitted) return;
          if (await _verifyWebViewSession()) {
            _autoLoginSubmitted = true;
            _cancelLoginPrefillTimers();
            return;
          }
          await _prefillWooCommerceLoginCredentials();
          if (!await _pageHasCaptchaChallenge() &&
              await _pageHasLoginForm()) {
            await _submitWooCommerceLoginIfNeeded();
            _cancelLoginPrefillTimers();
          }
        }),
      );
    }
  }

  Future<bool> _pageHasLoginForm() async {
    try {
      final result = await _controller.runJavaScriptReturningResult('''
(function() {
  if (document.querySelector('form.woocommerce-form-login')) return 'yes';
  if (document.querySelector('form.login input[name="username"], form.login input[name="log"]')) return 'yes';
  if (document.querySelector('#username') && document.querySelector('#password')) return 'yes';
  return 'no';
})()
''');
      return result.toString().replaceAll('"', '').trim() == 'yes';
    } catch (_) {
      return false;
    }
  }

  static String _normalizePath(String path) {
    if (path.length > 1 && path.endsWith('/')) {
      return path.substring(0, path.length - 1);
    }
    return path;
  }

  bool _urlsMatchStoreTarget(String finishedUrl) {
    final target = Uri.tryParse(widget.initialUrl);
    final current = Uri.tryParse(finishedUrl);
    if (target == null || current == null) return false;
    if (target.host != current.host) return false;
    return _normalizePath(target.path) ==
        _normalizePath(current.path);
  }

  bool _sameCheckoutOrCartFlow(Uri target, Uri current) {
    final ta = target.path.toLowerCase();
    final ca = current.path.toLowerCase();
    if (ta.contains('checkout') && ca.contains('checkout')) return true;
    if (ta.contains('cart') && ca.contains('cart')) return true;
    return false;
  }

  void _maybeDismissBlockingOverlay(String finishedUrl) {
    if (!_blockingOverlay) return;
    if (_adding) return;

    if (_urlsMatchStoreTarget(finishedUrl)) {
      setState(() => _blockingOverlay = false);
      _overlayFailsafeTimer?.cancel();
      return;
    }

    final target = Uri.tryParse(widget.initialUrl);
    final current = Uri.tryParse(finishedUrl);
    if (target != null &&
        current != null &&
        target.host == current.host &&
        _sameCheckoutOrCartFlow(target, current)) {
      setState(() => _blockingOverlay = false);
      _overlayFailsafeTimer?.cancel();
    }
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
  String _targetAfterBridge() {
    if (_addQueue.isNotEmpty) return '$kStoreBaseUrl/';
    return widget.initialUrl;
  }

  /// Navigation-based one-time code bridge (redirect only — never shows JSON).
  Future<bool> _startCodeNavigationBridge() async {
    if (kIsWeb) return false;
    final code = await AuthService.instance.mintWebSessionCodeWithRetry();
    if (code == null || code.isEmpty) return false;

    _postBridgeTargetUrl = _targetAfterBridge();
    _bridgeNavigationPending = true;
    final bridgeUrl = buildWebSessionCodeLaunchUrl(
      code: code,
      redirectUrl: _postBridgeTargetUrl!,
    );
    if (kDebugMode) {
      debugPrint('[StoreWebView] code navigation bridge → $bridgeUrl');
    }
    await _controller.loadRequest(Uri.parse(bridgeUrl));
    return true;
  }

  Future<void> _retrySafeWebSessionBridge() async {
    if (!mounted || !widget.attemptWebLogin) return;
    _bridgeNavigationPending = false;
    _authBootstrapDone = false;
    _autoLoginSubmitted = false;
    await _establishWebSessionAndLoadTarget();
  }

  Future<void> _redirectToStorefrontLogin() async {
    if (!AuthService.instance.hasWebLoginCredentials) return;
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
    _scheduleLoginPrefillRetries();
  }

  Future<void> _resetWebViewCookiesForAuth() async {
    try {
      await _cookieManager.clearCookies();
    } catch (_) {}
    await _injectStoreCartCookies();
  }

  Future<void> _establishWebSessionAndLoadTarget() async {
    await AuthService.instance.ensureValidSession();
    // Keep Cloudflare clearance cookies — clearing the jar triggers a new
    // Turnstile challenge on every subsequent WebView open.
    await _injectStoreCartCookies();

    if (await _startCodeNavigationBridge()) return;

    final bridged = await StoreCartApiService.instance
        .establishWebSessionForWebView(_cookieManager);
    _authBootstrapDone = true;
    if (bridged) {
      if (_addQueue.isNotEmpty) {
        await _startAddToCartQueue();
      } else {
        await _controller.loadRequest(Uri.parse(widget.initialUrl));
      }
      return;
    }

    // Session bridge failed — storefront login with credential prefill.
    await _fallbackToFormLoginOrTarget();
  }

  Future<void> _injectCookiesAndLoad() async {
    if (widget.attemptWebLogin) {
      await _establishWebSessionAndLoadTarget();
      return;
    }
    // No auth needed: inject cookies then immediately start queue or load target.
    await _injectStoreCartCookies();
    if (_addQueue.isNotEmpty) {
      await _startAddToCartQueue();
    } else {
      await _controller.loadRequest(Uri.parse(widget.initialUrl));
    }
  }

  Future<void> _startAddToCartQueue() async {
    if (_addFlowStarted) return;
    _addFlowStarted = true;
    _addIndex = 0;
    _adding = true;

    final first = _addQueue[0];
    final addUrl = storeAddToCartUrl(first.productId, quantity: first.quantity);
    if (kDebugMode) {
      debugPrint(
        '[StoreWebView] startAddQueue: productId=${first.productId} qty=${first.quantity} url=$addUrl',
      );
    }
    await _controller.loadRequest(Uri.parse(addUrl));
  }

  Future<void> _completeNavigationBridge(String finishedUrl) async {
    _bridgeNavigationPending = false;
    _authBootstrapDone = true;

    // Allow Set-Cookie + redirect to settle (iOS needs longer than 250ms).
    final settleMs = defaultTargetPlatform == TargetPlatform.iOS ? 800 : 400;
    await Future<void>.delayed(Duration(milliseconds: settleMs));

    var sessionOk = await _verifyWebViewSession();
    if (!sessionOk) {
      if (kDebugMode) {
        debugPrint('[StoreWebView] navigation bridge: verifying via POST fetch');
      }
      if (await _tryJwtCookieBridge()) {
        await Future<void>.delayed(Duration(milliseconds: settleMs));
        sessionOk = await _verifyWebViewSession();
      }
    }

    if (sessionOk) {
      _autoLoginSubmitted = true;
      if (kDebugMode) {
        debugPrint('[StoreWebView] WebView session verified after bridge');
      }
      await _continueAfterAuthBootstrap(finishedUrl);
      return;
    }

    if (kDebugMode) {
      debugPrint(
        '[StoreWebView] bridge did not establish session — login fallback',
      );
    }
    await _resetWebViewCookiesForAuth();
    await _fallbackToFormLoginOrTarget();
  }

  static bool _isAccountDeepLink(Uri uri) {
    final p = uri.path.toLowerCase();
    return p.contains('/my-account/orders') ||
        p.contains('/my-account/view-order') ||
        p.contains('/my-account/edit-account') ||
        p.contains('/my-account/lost-password');
  }

  Future<void> _continueAfterAuthBootstrap(String currentUrl) async {
    if (_addQueue.isNotEmpty) {
      await _startAddToCartQueue();
      return;
    }
    final target = _postBridgeTargetUrl ?? widget.initialUrl;
    final want = Uri.tryParse(target);
    if (want != null && _isAccountDeepLink(want)) {
      final current = Uri.tryParse(currentUrl);
      if (current == null ||
          _normalizePath(current.path) != _normalizePath(want.path)) {
        await _controller.loadRequest(want);
      }
      return;
    }
    final current = Uri.tryParse(currentUrl);
    if (current != null &&
        want != null &&
        current.host == want.host &&
        _normalizePath(current.path) == _normalizePath(want.path)) {
      return;
    }
    await _controller.loadRequest(Uri.parse(target));
  }

  /// Bridge failed — open the WooCommerce my-account login form (not wp-login.php)
  /// and auto-fill stored app credentials when no captcha is present.
  Future<void> _fallbackToFormLoginOrTarget() async {
    if (AuthService.instance.hasWebLoginCredentials) {
      final loginUrl = storeMyAccountLoginUrl(
        accountType: AuthService.instance.webAccountTypeForStoreLogin,
      );
      final redirectTo = widget.initialUrl;
      await _controller.loadRequest(
        Uri.parse(loginUrl).replace(
          queryParameters: {
            ...Uri.parse(loginUrl).queryParameters,
            'redirect_to': redirectTo,
          },
        ),
      );
      _autoLoginSubmitted = false;
      _scheduleLoginPrefillRetries();
      return;
    }
    _autoLoginSubmitted = true;
    if (_addQueue.isNotEmpty) {
      await _startAddToCartQueue();
    } else {
      await _controller.loadRequest(Uri.parse(widget.initialUrl));
    }
  }

  Future<void> _bootstrapWebSession() async {
    _authBootstrapDone = true;
    final bridged = await _tryJwtCookieBridge();
    if (bridged && await _verifyWebViewSession()) {
      _autoLoginSubmitted = true;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _continueAfterAuthBootstrap('');
      return;
    }
    await _fallbackToFormLoginOrTarget();
  }

  /// True when WP REST sees the WebView cookie jar as logged in.
  Future<bool> _verifyWebViewSession() async {
    try {
      final result = await _controller.runJavaScriptReturningResult('''
(function() {
  return fetch('/wp-json/wp/v2/users/me', {
    credentials: 'include',
    headers: { 'Accept': 'application/json' }
  }).then(function(r) { return r.status === 200 ? 'ok' : 'fail_' + r.status; })
    .catch(function() { return 'error'; });
})()
''');
      final text = result.toString().replaceAll('"', '').trim();
      if (kDebugMode) {
        debugPrint('[StoreWebView] users/me verify → $text');
      }
      return text == 'ok';
    } catch (_) {
      return false;
    }
  }

  Future<bool> _pageHasCaptchaChallenge() async {
    try {
      final result = await _controller.runJavaScriptReturningResult('''
(function() {
  if (document.querySelector('.cerber-form, .g-recaptcha, .h-captcha, .cf-turnstile')) return 'yes';
  if (document.querySelector('iframe[src*="captcha"], iframe[src*="challenges.cloudflare"]')) return 'yes';
  var t = (document.body && document.body.innerText) ? document.body.innerText.toLowerCase() : '';
  if (t.indexOf('confirm you are not a robot') >= 0 || t.indexOf('captcha') >= 0) return 'maybe';
  return 'no';
})()
''');
      final text = result.toString().replaceAll('"', '').trim();
      return text == 'yes' || text == 'maybe';
    } catch (_) {
      return false;
    }
  }

  Future<void> _prefillWooCommerceLoginCredentials() async {
    final email = AuthService.instance.webLoginEmail;
    final password = AuthService.instance.webLoginPassword;
    if (email == null || password == null) return;
    final js = '''
(function() {
  var f = document.querySelector('form.woocommerce-form-login');
  if (!f) f = document.querySelector('form.login');
  if (!f) return 'no-login-form';
  var u = f.querySelector('input[name="username"]') || f.querySelector('input[name="log"]') || document.querySelector('#username');
  var p = f.querySelector('input[name="password"]') || f.querySelector('input[name="pwd"]') || document.querySelector('#password');
  if (!u || !p) return 'no-login-form';
  u.value = '${_escapeJs(email)}';
  p.value = '${_escapeJs(password)}';
  try { u.dispatchEvent(new Event('input', { bubbles: true })); } catch (e) {}
  try { p.dispatchEvent(new Event('input', { bubbles: true })); } catch (e) {}
  return 'prefilled';
})();
''';
    try {
      await _controller.runJavaScriptReturningResult(js);
    } catch (e) {
      debugPrint('WebView login prefill error: $e');
    }
  }

  Future<void> _submitWooCommerceLoginIfNeeded() async {
    if (_autoLoginSubmitted) return;
    final email = AuthService.instance.webLoginEmail;
    final password = AuthService.instance.webLoginPassword;
    if (email == null || password == null) return;
    final js = '''
(function() {
  var f = document.querySelector('form.woocommerce-form-login');
  if (!f) return 'no-login-form';
  var u = f.querySelector('input[name="username"]') || document.querySelector('#username');
  var p = f.querySelector('input[name="password"]') || document.querySelector('#password');
  if (!u || !p) return 'no-login-form';
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
      if (text != 'submitted') return;
      _autoLoginSubmitted = true;
    } catch (e) {
      debugPrint('WebView WooCommerce auto-login error: $e');
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
  Future<bool> _pullCartJsonFromWebView() async {
    try {
      // Give server a moment to settle session after add-to-cart redirect.
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      if (kDebugMode) {
        debugPrint('[StoreWebView] pullCart: fetching /wp-json/wc/store/v1/cart via JS');
      }
      // Use JS fetch with credentials:include so the WebView's HttpOnly cookies
      // (wp_woocommerce_session_*) are sent — the app's http.Client can't see these.
      final result = await _controller.runJavaScriptReturningResult('''
(function() {
  return fetch('/wp-json/wc/store/v1/cart?_cb=' + Date.now(), {
    credentials: 'include',
    cache: 'no-store',
    headers: { 'Accept': 'application/json', 'Cache-Control': 'no-cache', 'Pragma': 'no-cache' }
  }).then(function(r) {
    return r.text();
  }).catch(function(e) { return ''; });
})()
''');
      // runJavaScriptReturningResult returns the JS string JSON-encoded.
      // So we get back a quoted string: '"{ ... }"'. Decode once.
      String raw = result.toString().trim();
      if (raw.startsWith('"') && raw.endsWith('"') && raw.length >= 2) {
        try {
          raw = jsonDecode(raw) as String;
        } catch (_) {
          raw = raw.substring(1, raw.length - 1)
              .replaceAll(r'\"', '"')
              .replaceAll(r'\n', '\n');
        }
      }
      if (raw.isEmpty || raw == 'null' || raw == '{}') return false;

      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return false;
      final items = decoded['items'];
      if (items is! List) return false;
      if (kDebugMode) {
        debugPrint('[StoreWebView] pullCart: got ${items.length} items from store');
      }
      await StoreCartApiService.instance.absorbCartSessionFromCartJson(decoded);
      if (!mounted) return false;
      await ref.read(cartProvider.notifier).applyStoreCartFromJson(decoded);
      return true;
    } catch (e) {
      debugPrint('[StoreWebView] pullCart error: $e');
      return false;
    }
  }

  /// Sync cart + cookies after checkout/cart changes in the WebView.
  Future<void> _syncAfterWebView() async {
    final pulledOk = await _pullCartJsonFromWebView();
    await _syncCookiesBack();
    if (!mounted) return;
    if (!pulledOk) {
      await ref.read(cartProvider.notifier).refreshFromRemote();
    }
    if (!mounted) return;
    ref.invalidate(wooCartProvider);
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
            : Stack(
                children: [
                  Positioned.fill(child: WebViewWidget(controller: _controller)),
                  if (_blockingOverlay)
                    Positioned.fill(
                      child: Material(
                        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.92),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 40,
                                height: 40,
                                child: CircularProgressIndicator(strokeWidth: 3),
                              ),
                              const SizedBox(height: 20),
                              Text(
                                'Preparing store…',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 8),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 32),
                                child: Text(
                                  'Syncing your cart with the website can take a few seconds.',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.7),
                                      ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    ),
    );
  }
}
