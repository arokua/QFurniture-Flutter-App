# Change log — catalog bugfixes (2026-03-29)

## Summary

Addressed four catalog-related issues: category ordering on the Categories tab, search stability, stock text containing HTML, and a cluttered category filter row on the main catalog.

## 1. Categories tab — order matches WooCommerce menu

**Files:** `lib/features/catalog/domain/category.dart`, `lib/features/catalog/data/category_repository.dart`

- Parse `menu_order` from the Store API as `int` or string (WooCommerce may send either).
- `buildCategoryTree` now sorts **root categories and children** by `menu_order` ascending, then by name when order ties.
- Extended `allowedParentSlugs` with Qtoys slugs: `toys-and-educational-resources`, `furniture-and-preschool-equipment`, `bundles`, `by-age-group`.
- Fallback offline categories include explicit `menuOrder` values so demo ordering is stable.

## 2. Search — no full HTML description scan

**File:** `lib/features/catalog/presentation/product_list_screen.dart`

- Added `productMatchesSearchQuery`: matches **name**, **SKU**, **category** strings, **material**, **color** — **not** the full `description` field (often large HTML), which caused UI jank and app termination on some devices.

## 3. Stock text — strip HTML

**Files:** `lib/features/catalog/utils/html_utils.dart`, `lib/features/catalog/domain/product.dart`, `lib/services/product_sync_service.dart`, `fetch_woocommerce_products.py`

- Added `stripHtmlTags` and `normalizeStockDisplay` in `html_utils.dart`.
- `Product.fromJson` normalizes `stockAmount` through `normalizeStockDisplay`.
- `ProductSyncService._normalizeRemoteProduct` normalizes API stock text before caching.
- Python `fetch_woocommerce_products.py`: `strip_html_tags` applied to `stock_amount` when writing `products.json`.

## 4. Main catalog — three expandable category groups

**Files:** `lib/features/catalog/domain/catalog_category_groups.dart` (new), `lib/features/catalog/presentation/product_list_screen.dart`

- Replaced one long horizontal list of all category chips with:
  - A single **All** chip row.
  - Three **ExpansionTile** sections: *Toys & Educational*, *Furniture & Preschool*, *Homewares & More*, each containing only the subcategory chips for that bucket (mapping by label heuristics in `catalog_category_groups.dart`).
- Tiles use subtle `surfaceContainerHighest` backgrounds and outline borders to reduce visual clash; selected category in a group is shown in the tile subtitle when collapsed.

## Files touched

- `lib/features/catalog/utils/html_utils.dart`
- `lib/features/catalog/domain/product.dart`
- `lib/features/catalog/domain/category.dart`
- `lib/features/catalog/domain/catalog_category_groups.dart` (new)
- `lib/features/catalog/data/category_repository.dart`
- `lib/features/catalog/presentation/product_list_screen.dart`
- `lib/services/product_sync_service.dart`
- `fetch_woocommerce_products.py`
