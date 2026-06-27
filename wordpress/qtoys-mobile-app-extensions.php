<?php
/**
 * Plugin Name: Qtoys Mobile App Extensions
 * Description: JWT-authenticated my-orders endpoint for the Qtoys partner app.
 * Version: 1.0.0
 * Author: Qtoys
 *
 * Deploy alongside qtoys-mobile-session (v1.2+). Provides:
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
        'permission_callback' => 'qtoys_rest_require_jwt_user',
    ]);
});

/**
 * Allow any authenticated WP user (JWT sets current user).
 */
function qtoys_rest_require_jwt_user() {
    return is_user_logged_in();
}

/**
 * List orders for the current user (same data shape as wc/v3/orders items).
 */
function qtoys_rest_my_orders(WP_REST_Request $request) {
    if (!function_exists('wc_get_orders')) {
        return new WP_REST_Response([], 200);
    }

    $user_id  = get_current_user_id();
    $per_page = min(50, max(1, (int) $request->get_param('per_page') ?: 25));

    $orders = wc_get_orders([
        'customer_id' => $user_id,
        'limit'       => $per_page,
        'orderby'     => 'date',
        'order'       => 'DESC',
        'return'      => 'objects',
    ]);

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
