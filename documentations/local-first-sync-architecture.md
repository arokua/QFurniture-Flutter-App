# Local-first sync architecture

## Principle

**Smooth UX first → UI second → backend synchrony third.**

The app never blocks the user on network calls for cart or order history. Local JSON is the render source; WordPress/WooCommerce sync runs in the background.

## What is implemented

### Cart (`lib/services/cart_cache_service.dart`, `lib/services/cart_sync_service.dart`)

| Step | Behaviour |
|------|-----------|
| User adds/removes/qty | `cartProvider` updates SharedPreferences **and** writes JSON immediately (`syncStatus: pending`) |
| Cart screen open | `wooCartProvider` reads JSON first → renders instantly |
| Background | `CartSyncService.syncNow()` fetches Store API, merges, updates JSON (`synced` / `failed`) |
| Periodic / resume | `CartRemoteSyncBinding` triggers background sync every 3 min + on app resume |
| Checkout complete | Cart JSON cleared; redirect to home (`PostCheckoutNavigation.go()`) |

Files: `{documents}/cart_cache/cart_{userKey}.json`

### Order history (existing + extended)

| Step | Behaviour |
|------|-----------|
| Screen open | `orderHistoryProvider` reads `orders_{userKey}.json` first |
| Background | `OrderHistorySyncService.syncNow()` merges REST orders into JSON |
| Wholesale checkout | Writes **pending** order to JSON before API call; resolves to **synced** or **failed** after response |
| Web checkout | Thank-you URL detected → order written as **synced** → immediate home redirect |

Files: `{documents}/order_history_cache/orders_{userKey}.json`

### Post-checkout navigation

`CheckoutConfirmation.complete()` writes the order locally, then calls `PostCheckoutNavigation.go()` → `/home` with no blocking dialog.

## Dev / QA toggle

```dart
// lib/config/local_first_sync_config.dart
static const bool showSyncStatusAndLogging = false;
```

Set to `true` to show sync chips on cart and order history screens and emit `[LocalSync]` debug logs.

## Co-syncing with WordPress without UI lag

```
┌─────────────┐     write-through      ┌──────────────┐
│  UI action  │ ─────────────────────► │  JSON cache  │
└─────────────┘                        └──────┬───────┘
                                              │ instant read
                                              ▼
                                       ┌──────────────┐
                                       │  Riverpod    │──► Cart / Orders UI
                                       └──────────────┘
                                              ▲
                                              │ merge (background)
┌─────────────┐     debounced fetch    ┌──────┴───────┐
│ WooCommerce │ ◄─────────────────────── │ SyncService  │
│  Store/REST │                        └──────────────┘
└─────────────┘
```

**Why this avoids lag**

1. Disk I/O is async and small (atomic `.tmp` → rename).
2. UI providers return cached data synchronously on first frame.
3. Network runs in `unawaited` background futures — never `await` before paint.
4. Debounced sync (3 min cart, 15 min orders) prevents request storms.
5. Failed remote sync keeps last good cache; UI still works offline.

## Limitations (honest constraints)

### Cannot guarantee perfect real-time parity

WooCommerce maintains **separate sessions** for:

- Mobile app Store API (`Cart-Token` + cookies)
- In-app WebView (browser cookies)
- External browser tabs

A user can edit the cart on the website while the app shows cached data until the next background sync. This is a **platform constraint**, not a Flutter limitation.

### Retail web checkout order creation

Orders placed inside the WebView are created on the server **before** the app detects the thank-you URL. The app cannot mark them `pending` beforehand; it writes them as `synced` once the URL is parsed.

### Wholesale / native checkout

True `pending → synced/failed` lifecycle applies here because the app controls the REST call.

### Conflict resolution

Current merge strategy: **remote wins for confirmed orders**; local `pending`/`failed` rows are kept until resolved. There is no operational-transform or CRDT — simultaneous edits on two devices may briefly diverge until the next sync.

### Guest users

Guest cart uses the same JSON file (`cart_guest.json`) via write-through. No remote cart exists until sign-in.

## Key files

| File | Role |
|------|------|
| `lib/config/local_first_sync_config.dart` | Dev toggle + intervals |
| `lib/services/cart_cache_service.dart` | Cart JSON persistence |
| `lib/services/cart_sync_service.dart` | Cart background sync |
| `lib/services/order_history_cache_service.dart` | Order JSON persistence |
| `lib/services/order_history_sync_service.dart` | Order background sync + pending lifecycle |
| `lib/features/cart/data/woo_cart_provider.dart` | Cache-first cart provider |
| `lib/navigation/checkout_confirmation.dart` | Write-through + home redirect |
| `lib/widgets/local_sync_status_chip.dart` | Dev sync badges |

## Testing checklist

1. Add items offline → cart shows items from JSON; sync badge shows `pending` (toggle on).
2. Open cart signed in with airplane mode → cached cart still renders.
3. Wholesale checkout → order appears as `pending` in history, then `synced` or `failed`.
4. Web checkout thank-you → lands on home tab immediately.
5. Pull-to-refresh cart → triggers `syncNow(force: true)` without blocking list paint.
