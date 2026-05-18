<?php
/**
 * Plugin Name: Qtoys JWT Cookie Bridge
 * Description: Add-on endpoint for "JWT Authentication for WP REST API". Converts a valid JWT bearer token into WP/Woo browser cookies for WebView SSO.
 * Version: 1.0.0
 * Author: Qtoys
 */

if (!defined('ABSPATH')) {
    exit;
}

add_action('rest_api_init', function () {
    register_rest_route('qtoys/v1', '/mobile-session', [
        'methods'             => ['POST', 'GET'],
        'callback'            => 'qtoys_jwt_cookie_bridge_callback',
        'permission_callback' => '__return_true',
    ]);
});

function qtoys_jwt_cookie_bridge_callback(WP_REST_Request $request) {
    $method = strtoupper($request->get_method());

    // POST: Authorization: Bearer <jwt>
    // GET:  ?token=<jwt>&redirect_to=<url>
    $token = null;
    if ($method === 'GET') {
        $token = $request->get_param('token');
    } else {
        $auth = $request->get_header('authorization');
        if (!$auth || stripos($auth, 'Bearer ') !== 0) {
            return new WP_REST_Response([
                'success' => false,
                'message' => 'Missing Bearer token',
            ], 401);
        }
        $token = trim(substr($auth, 7));
    }

    $token = is_string($token) ? trim($token) : '';
    if ($token === '') {
        return new WP_REST_Response([
            'success' => false,
            'message' => 'Empty token',
        ], 401);
    }

    // Validate token using the JWT plugin's own endpoint.
    $validate_url = rest_url('jwt-auth/v1/token/validate');
    $resp = wp_remote_post($validate_url, [
        'headers' => [
            'Authorization' => 'Bearer ' . $token,
            'Accept'        => 'application/json',
        ],
        'timeout' => 10,
    ]);

    if (is_wp_error($resp)) {
        return new WP_REST_Response([
            'success' => false,
            'message' => 'Token validation failed',
        ], 401);
    }

    $status = wp_remote_retrieve_response_code($resp);
    if ($status < 200 || $status >= 300) {
        return new WP_REST_Response([
            'success' => false,
            'message' => 'Token invalid',
        ], 401);
    }

    // Decode JWT payload to resolve the WP user.
    $parts = explode('.', $token);
    if (count($parts) !== 3) {
        return new WP_REST_Response([
            'success' => false,
            'message' => 'Malformed token',
        ], 401);
    }

    $payload_json = qtoys_jwt_cookie_bridge_base64url_decode($parts[1]);
    $payload = json_decode($payload_json, true);
    if (!is_array($payload)) {
        return new WP_REST_Response([
            'success' => false,
            'message' => 'Invalid token payload',
        ], 401);
    }

    $user_id = null;
    if (isset($payload['data']['user']['id'])) {
        $user_id = intval($payload['data']['user']['id']);
    }
    if (!$user_id && isset($payload['sub'])) {
        $user_id = intval($payload['sub']);
    }

    if (!$user_id) {
        return new WP_REST_Response([
            'success' => false,
            'message' => 'User id not found in token',
        ], 401);
    }

    $user = get_user_by('id', $user_id);
    if (!$user || !$user->ID) {
        return new WP_REST_Response([
            'success' => false,
            'message' => 'User not found',
        ], 401);
    }

    wp_set_current_user($user->ID);
    wp_set_auth_cookie($user->ID, true, is_ssl());
    do_action('wp_login', $user->user_login, $user);

    // Prime WooCommerce session/cart cookie if Woo is active.
    if (function_exists('WC') && WC()->session) {
        WC()->session->set_customer_session_cookie(true);
    }

    if ($method === 'GET') {
        // External browser flow: redirect back to the requested store URL.
        $redirect_to = $request->get_param('redirect_to');
        if (!$redirect_to) {
            $redirect_to = $request->get_param('redirect');
        }
        if (!$redirect_to) {
            $redirect_to = home_url('/');
        }

        $redirect_to = esc_url_raw($redirect_to);
        wp_safe_redirect($redirect_to);
        exit;
    }

    return new WP_REST_Response([
        'success' => true,
        'user_id' => $user->ID,
        'message' => 'Web session cookies established',
    ], 200);
}

function qtoys_jwt_cookie_bridge_base64url_decode($data) {
    $remainder = strlen($data) % 4;
    if ($remainder) {
        $data .= str_repeat('=', 4 - $remainder);
    }
    return base64_decode(strtr($data, '-_', '+/'));
}

