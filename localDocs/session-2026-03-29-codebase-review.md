# Session log — codebase review (2026-03-29)

**Scope:** Explored `lib/` Dart sources and root Python utilities. **No application code was modified** in this session.

## Project shape

- **Flutter app** (`Qtoys`, `pubspec.yaml`): Material 3, Riverpod, go_router, cached_network_image, http, shared_preferences, webview_flutter.
- **Entry:** `main.dart` — loads `.env`, initializes `StoreCartApiService` (WC Store API cart + cookie persistence), `AuthService` (WP JWT + WC customer lookup/registration), pre-warms `ProductSyncService`.
- **Routing:** `app_router.dart` — splash, login, register, tabbed home (catalog / categories / more), cart, favorites, product detail, store WebView. Redirect forces login except splash/login.
- **Catalog data flow:** `ProductRepository` ← local + remote datasources; `ProductSyncService` fetches WC Store API products, caches in SharedPreferences, normalizes prices/stock/categories; fallback to bundled `assets/data/products.json`.
- **Categories (API):** `CategoryRepository` → `wc/store/v1/products/categories`; tree built in `category.dart` (`buildCategoryTree`). Filter uses `allowedParentSlugs`; fallback static list if API fails.
- **Auth:** `AuthService` — JWT login, WC v3 customers for registration with `meta_data` (abn, phone, website_url). **Registration UI** already exposes roles: `customers`, `wholesale`, `retailer`, `dropshipping` with conditional ABN/website (and phone) for the three B2B roles.

## Python utilities

| File | Role |
|------|------|
| `fetch_woocommerce_products.py` | Batch-fetch Store API products → `assets/data/products.json` (aligned with app’s normalized shape: prices, categories, stock text, attributes). |
| `download_product_images.py` | Downloads images referenced in JSON (not read in full this session). |
| `parse_wc.py` | Small probe script (SKU search → JSON). |
| `check_stock.py` | Stock helper (not read in full). |
| `update_pubspec.py` | Pubspec maintenance (not read in full). |

**Note:** Role-specific **base pricing** from JSON is not evident in `fetch_woocommerce_products.py` (single `price` / sale / regular from Store API). Tiered B2B pricing likely needs WC plugins or authenticated REST and app-side mapping — future work.

## Gap vs stated goals (no implementation this session)

- **RBAC:** Registration/login scaffolding exists; **approval workflow**, admin assignment, and **price tier by role** are not implemented in the reviewed paths.
- **Order tracking / history:** Not surfaced in reviewed screens; would need WC orders API + customer ID (`AuthService` stores `customerId`).
- **Checkout / Apple Pay / Google Pay:** Cart syncs to Store API; checkout appears WebView-oriented (`StoreWebViewScreen`, `store_cart_url`). Native wallets and durable checkout state are future scope.

## Bug mapping (for upcoming implementation)

1. **Categories tab order** — `buildCategoryTree` sorts root categories **alphabetically by name** and children the same way; **`menu_order` from API is ignored** (`Category.menuOrder` exists but unused). Misalignment with “specified order” likely here. Also `allowedParentSlugs` / fallback names may drift from live Qtoys taxonomy.

2. **Search crash / overload** — `filteredProductsProvider` matches `p.description` (often large HTML) on every query. High CPU/memory and jank; likely root of “crash on press” as list rebuilds.

3. **Stock text shows HTML** — `stockAmount` is passed through from API/sync without stripping tags. `decodeHtmlEntities` in `html_utils.dart` does not remove `<span>` etc. Affects quick view (`product_list_screen.dart`) and detail chips (`product_detail_screen.dart`).

4. **Cluttered category chips on catalog** — `categoriesProvider` builds a horizontal list of **all** distinct categories from products. User request: **~3 main categories** expanding to subcategories with careful layout/theming.

## Files touched in this session

- **Created:** `localDocs/session-2026-03-29-codebase-review.md` (this file).
