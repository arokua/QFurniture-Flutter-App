# Change log — cart sync, shipping (Store API), registration order, login (2026-03-29)

## Research (WooCommerce Store API)

- **GET `/wp-json/wc/store/v1/cart`** returns the full cart: `items`, `totals` (including `total_shipping`, `total_price` in **minor units** as strings), `shipping_rates` (packages and selectable methods), and `has_calculated_shipping`. No nonce required for GET.
- **POST `/wp-json/wc/store/v1/cart/update-item`** and **POST `.../cart/remove-item`** are the documented update/remove flows (often with `?key=&quantity=`). Some older integrations used `PUT`/`DELETE` on `/cart/items/...`; this project tries the documented POST first, then falls back.
- **POST** mutating routes may require a [Cart Token or Nonce](https://developer.woocommerce.com/docs/apis/store-api/nonce-tokens) on stricter sites; cookie-based sessions often still work for the same session that created the cart.

## Cart

### `lib/config/store_cart_api_service.dart`

- Added **`fetchFullCart()`** → GET `/cart` with `(success, data)` so callers do not treat network errors as an empty cart.
- **Update line quantity:** POST `/cart/update-item` (fallback: legacy PUT with query).
- **Remove line:** POST `/cart/remove-item` (fallback: legacy DELETE).
- **`clearCart`:** removes each line via `removeItem` (no reliance on a single bulk DELETE).

### `lib/features/cart/data/store_cart_json.dart` (new)

- **`cartItemsFromStoreCartJson`** — maps Store API `items[]` to local `CartItem`s.
- **`StoreCartTotalsView`** — reads `totals` + `has_calculated_shipping` for UI copy and formatted shipping / order total lines.

### `lib/features/cart/data/cart_provider.dart`

- Startup sync uses **`fetchFullCart`** when a session exists (success-only; avoids wiping local cart on failure).
- **`refreshFromRemote`** uses full cart JSON (same as above).
- **`applyStoreCartFromJson`** for WebView-pulled JSON.
- **`storeCartTotalsProvider`** — `FutureProvider.autoDispose` for cart summary shipping / order total when a session exists.

### `lib/features/cart/presentation/cart_screen.dart`

- Summary shows **subtotal (catalog prices)**, optional **Store API shipping line** and **order total** from `storeCartTotalsProvider`, and invalidates totals after successful checkout sync.

## WebView ↔ app cart

### `lib/features/catalog/presentation/store_webview_screen.dart`

- On close (X) **or system back** (`PopScope`, `canPop: false`), runs:
  1. **`fetch('/wp-json/wc/store/v1/cart')`** in the page context (sends **HttpOnly** session cookies) → **`applyStoreCartFromJson`**
  2. **`document.cookie`** sync into `StoreCartApiService` (for non-HttpOnly crumbs)
  3. **`refreshFromRemote()`** when a persisted cookie session exists
- Fixes cases where **`document.cookie` alone could not see the WooCommerce session cookie**.

## Registration / login

### `lib/features/auth/presentation/registration_screen.dart`

- **Account type** dropdown order: **Wholesale → Dropship → Retailer → Normal** (`_roleOrder`). Labels unchanged; validators still use `_roleLabels`.

### `lib/features/auth/presentation/login_screen.dart`

- **Skip for now** now **`await`s** `signIn` and only navigates home on success; otherwise shows the error (no race with `go_router`).

## Files touched

- `lib/config/store_cart_api_service.dart`
- `lib/features/cart/data/store_cart_json.dart` (new)
- `lib/features/cart/data/cart_provider.dart`
- `lib/features/cart/presentation/cart_screen.dart`
- `lib/features/catalog/presentation/store_webview_screen.dart`
- `lib/features/auth/presentation/registration_screen.dart`
- `lib/features/auth/presentation/login_screen.dart`

## Android crash: `EditorInfoCompat.setStylusHandwritingEnabled` (NoSuchMethodError)

**Symptom:** Crash when focusing a text field (login/register), after `showSoftInput`.

**Cause:** `android/app/build.gradle` forced `androidx.core:core:1.12.0`. Current Flutter’s `TextInputPlugin` calls `EditorInfoCompat.setStylusHandwritingEnabled`, which was added in a **newer** AndroidX Core. At runtime the older JAR lacked the method → `NoSuchMethodError`.

**Fix:** Bump `androidx.core:core` and `core-ktx` to **1.16.0** (resolutionStrategy `force` + explicit `implementation`), and browser to **1.8.0**.

## Router fix (registration unreachable)

**Issue:** `redirect` only treated `/login` as allowed when signed out. Any other path (including `/register`) was sent to `/login`, so **Register never appeared**.

**Fix (`lib/app_router.dart`):** treat both `/login` and `/register` as public auth routes when signed out; if already signed in, navigating to login or register redirects to home.

## Guest browse / offline “Skip for now” (PWA-style)

**Issue:** “Skip” called `signIn` with fake credentials → network errors offline, “no route” / API failures online.

**Fix:** `AuthService.enterGuestBrowseMode()` sets a persisted `qf_auth_guest_browse` flag **with no HTTP**. Router uses `canAccessApp` (`isSignedIn || isGuestBrowse`) instead of only `isSignedIn`. Guests can still open **Login** from More to attach an account; `signOut` clears guest + account. Real `_persist` clears guest when logging in.

## User-facing API errors (WordPress `rest_no_route` etc.)

**Issue:** Raw REST messages like *"No route was found matching the URL and method"* were shown in the UI (looks like an app bug).

**Cause:** WordPress returns that `message` in JSON for 404/wrong-method routes; auth and some flows surfaced it verbatim.

**Fix:** `lib/utils/user_facing_errors.dart` — `sanitizeAuthApiMessage` / `userFacingCatalogError` map technical phrases to short copy; **technical details** go to `debugPrint` only. Applied in `AuthService`, product list/detail error states, and categories load failure.

## Cart tokens / nonces (implemented)

### Why we changed it
Some WooCommerce Store API hosts return a `401` error with:
- `woocommerce_rest_missing_nonce` / “Missing the Nonce header”.

In those cases, the app uses WooCommerce **Cart Tokens**:
- `GET /wp-json/wc/store/v1/cart` may include a `Cart-Token` response header
- the app sends `Cart-Token: <token>` on Store API POSTs.

### Code pointers
- `lib/config/store_cart_api_service.dart`: captures/persists `Cart-Token` and sends it in request headers.
- `lib/features/cart/presentation/cart_screen.dart`: when store sync fails, it opens “add-to-cart first”.

## Follow-ups

- **Guest / browse mode** instead of hard-coded test credentials for “Skip”.
- **Role approval** and **tiered pricing** remain server-side / WooCommerce configuration.
- External browser JWT bridge depends on your WordPress plugin supporting `GET /wp-json/qtoys/v1/mobile-session` redirect mode.
