# WordPress JWT and app URL alignment

The app authenticates with the **JWT Authentication for WP REST API** plugin (Enrique Chavez). The namespace used in code is:

- `POST {storeBaseUrl}/wp-json/jwt-auth/v1/token`  
  Body: JSON `{"username": "<email>", "password": "<password>"}`  
  Success: JSON includes `token`.

**Server requirements**

1. Install and activate **JWT Authentication for WP REST API** on the same WordPress site as WooCommerce.
2. Configure the plugin per its readme (often `JWT_AUTH_SECRET_KEY` in `wp-config.php` and rewrite rules so `/wp-json/jwt-auth/v1/token` is reachable).
3. **`storeBaseUrl` in the app** must be the same origin users use in the browser (scheme + host, no trailing slash issues). It is defined in `lib/config/store_config.dart` and typically loaded from `.env` / build config. If the app points at `https://example.com` but JWT is only enabled on `https://www.example.com`, login will fail.

**Registration** uses WooCommerce REST APIs separately; JWT is for login/session after the customer exists in WordPress/WooCommerce.

## Optional add-on: JWT -> WebView cookie bridge

To auto-sign-in users inside the in-app WebView (cart/account pages), add the plugin file:

- `localDocs/qtoys-jwt-cookie-bridge-plugin.php`

This creates:

- `POST /wp-json/qtoys/v1/mobile-session`

The app calls that endpoint from WebView with `Authorization: Bearer <jwt>`, and the endpoint sets WordPress/WooCommerce cookies for that browser session.

## External browser support (system browser)

For “open in browser” flows, the app can also wrap the target store URL with a JWT bridge.

The app uses (GET variant):

- `GET /wp-json/qtoys/v1/mobile-session?token=<jwt>&redirect_to=<absolute store url>`

Server requirements:
- The `qtoys/v1/mobile-session` route must support `GET` (in addition to `POST`) and must redirect the user to `redirect_to` after setting cookies.
- If your server/plugin only supports `POST`, set in `.env`:
  - `STORE_USE_JWT_BRIDGE_EXTERNAL=false`

Otherwise, external browser login can fail even when WebView login works.

## Registration fields and username mapping

The app’s registration form requires:
- `username` (store login name)
- `email`
- `password`

Optional:
- `first name` (sent as WooCommerce `first_name`)

The app maps:
- registration `username` -> WooCommerce customer REST field `username`
- registration `email` -> WooCommerce customer REST field `email`

## Role resolution for the UI

After login, the app attempts to determine the app “account type” (chip label) by:
1. Fetching WooCommerce customer role (prefer authenticated customer endpoints when possible).
2. Merging any role-like strings extracted from the JWT payload (including multi-role arrays / capability keys).
3. Falling back to the WordPress user endpoint with `context=edit` to read `roles`/`capabilities` when WooCommerce returns a generic `customer`.

The mapping logic lives in `lib/services/auth_service.dart` (`_extractRoleStringsFromJwt`, `_roleFromWooCustomerMap`, and related helpers).
