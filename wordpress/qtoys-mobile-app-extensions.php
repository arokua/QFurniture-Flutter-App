<?php
/**
 * Plugin Name: Qtoys Mobile App Extensions
 * Description: JWT-authenticated my-orders endpoint for the Qtoys partner app.
 * Version: 1.0.4
 * Author: Qtoys
 *
 * Deploy alongside qtoys-jwt-cookie-bridge (v1.3+). Provides:
 *   GET /wp-json/qtoys/v1/my-orders
 * Returns WooCommerce orders for the JWT-authenticated user.
 */

if (!defined('ABSPATH')) {
    exit;
}

add_action('rest_api_init', function () {
    register_rest_route('qtoys/v1', '/my-orders', [
        'methods'             => 'GET',
        'callback'            => 'qtoys_rest_my_orders',
        'permission_callback' => '__return_true',
    ]);
});

/**
 * Resolve WP user id from Bearer JWT (reuses qtoys-jwt-cookie-bridge helpers when present).
 */
function qtoys_rest_resolve_user_id_from_request(WP_REST_Request $request) {
    $token = '';
    if (function_exists('qtoys_jwt_cookie_bridge_token_from_bearer_header')) {
        $token = qtoys_jwt_cookie_bridge_token_from_bearer_header($request);
    } else {
        $auth = $request->get_header('authorization');
        if ($auth && stripos($auth, 'Bearer ') === 0) {
            $token = trim(substr($auth, 7));
        }
    }

    if ($token === '') {
        return 0;
    }

    if (function_exists('qtoys_jwt_cookie_bridge_resolve_user_id_from_token')) {
        return (int) qtoys_jwt_cookie_bridge_resolve_user_id_from_token($token);
    }

    // Minimal fallback when session plugin is not loaded.
    $parts = explode('.', $token);
    if (count($parts) !== 3) {
        return 0;
    }
    $payload_json = base64_decode(strtr($parts[1], '-_', '+/'));
    $payload = json_decode($payload_json, true);
    if (!is_array($payload)) {
        return 0;
    }
    if (isset($payload['data']['user']['id'])) {
        return (int) $payload['data']['user']['id'];
    }
    if (isset($payload['sub'])) {
        return (int) $payload['sub'];
    }
    return 0;
}

/**
 * List orders for the JWT user (same data shape as wc/v3/orders items).
 */
function qtoys_rest_my_orders(WP_REST_Request $request) {
    $user_id = qtoys_rest_resolve_user_id_from_request($request);
    if ($user_id <= 0) {
        return new WP_REST_Response([
            'code'    => 'qtoys_unauthorized',
            'message' => 'Valid Bearer JWT required.',
        ], 401);
    }

    if (!function_exists('wc_get_orders')) {
        return new WP_REST_Response(['orders' => []], 200);
    }

    $per_page = min(50, max(1, (int) $request->get_param('per_page') ?: 25));

    $order_args = [
        'limit'   => $per_page,
        'orderby' => 'date',
        'order'   => 'DESC',
        'return'  => 'objects',
        'status'  => 'any',
    ];

    $orders_by_id = wc_get_orders(array_merge($order_args, ['customer_id' => $user_id]));

    $user = get_userdata($user_id);
    $emails = [];
    if ($user && is_email($user->user_email)) {
        $emails[] = strtolower($user->user_email);
    }
    if (function_exists('wc_get_customer')) {
        $wc_customer = wc_get_customer($user_id);
        if ($wc_customer) {
            $billing = $wc_customer->get_billing_email();
            if (is_email($billing)) {
                $emails[] = strtolower($billing);
            }
        }
    }
    $emails = array_values(array_unique(array_filter($emails)));

    $orders = $orders_by_id;
    foreach ($emails as $email) {
        $by_email = wc_get_orders(array_merge($order_args, ['billing_email' => $email]));
        if (!empty($by_email)) {
            $orders = array_merge($orders, $by_email);
        }
    }

    // De-duplicate (customer_id + billing_email queries may overlap).
    $unique = [];
    foreach ($orders as $order) {
        if ($order instanceof WC_Order) {
            $unique[$order->get_id()] = $order;
        }
    }
    $orders = array_values($unique);
    usort($orders, function ($a, $b) {
        return $b->get_date_created()->getTimestamp() - $a->get_date_created()->getTimestamp();
    });
    $orders = array_slice($orders, 0, $per_page);

    $out = [];
    foreach ($orders as $order) {
        if (!$order instanceof WC_Order) {
            continue;
        }
        $lines = [];
        foreach ($order->get_items() as $item) {
            if (!$item instanceof WC_Order_Item_Product) {
                continue;
            }
            $lines[] = [
                'product_id' => (int) $item->get_product_id(),
                'quantity'   => (int) $item->get_quantity(),
                'name'       => $item->get_name(),
            ];
        }
        $out[] = [
            'id'           => $order->get_id(),
            'number'       => $order->get_order_number(),
            'status'       => $order->get_status(),
            'date_created' => $order->get_date_created() ? $order->get_date_created()->date('c') : '',
            'total'        => $order->get_total(),
            'currency'     => $order->get_currency(),
            'customer_id'  => (int) $order->get_customer_id(),
            'line_items'   => $lines,
        ];
    }

    return new WP_REST_Response(['orders' => $out], 200);
}

/**
 * When the app creates orders via wc/v3 REST, stamp account_type from the
 * customer's WP role if the client did not send meta (avoids default retail).
 */
add_filter('woocommerce_rest_pre_insert_shop_order_object', 'qtoys_rest_stamp_order_account_type', 10, 3);

function qtoys_rest_stamp_order_account_type($order, $request, $creating) {
    if (!$creating || !($order instanceof WC_Order)) {
        return $order;
    }

    $existing = $order->get_meta('account_type', true);
    if ($existing !== '' && $existing !== null) {
        return $order;
    }

    $body = $request->get_json_params();
    if (is_array($body) && !empty($body['meta_data']) && is_array($body['meta_data'])) {
        foreach ($body['meta_data'] as $meta) {
            if (!is_array($meta)) {
                continue;
            }
            $key = isset($meta['key']) ? (string) $meta['key'] : '';
            if ($key === 'account_type' && !empty($meta['value'])) {
                $order->update_meta_data('account_type', (string) $meta['value']);
                return $order;
            }
        }
    }

    $customer_id = (int) $order->get_customer_id();
    if ($customer_id <= 0) {
        return $order;
    }

    $user = get_userdata($customer_id);
    if (!$user || empty($user->roles)) {
        return $order;
    }

    $type = qtoys_map_wp_roles_to_account_type($user->roles);
    if ($type !== '') {
        $order->update_meta_data('account_type', $type);
    }

    return $order;
}

function qtoys_map_wp_roles_to_account_type(array $roles) {
    foreach ($roles as $role) {
        $r = strtolower((string) $role);
        if ($r === 'wholesale' || $r === 'wholesale_customer' || strpos($r, 'wholesale') !== false) {
            return 'wholesale';
        }
    }
    foreach ($roles as $role) {
        $r = strtolower((string) $role);
        if (strpos($r, 'dropship') !== false || $r === 'retailer') {
            return 'dropship';
        }
    }
    return 'customer';
}
