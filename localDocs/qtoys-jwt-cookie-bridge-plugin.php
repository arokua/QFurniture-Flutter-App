<?php
/**
 * Plugin Name: Qtoys JWT Cookie Bridge
 * Description: JWT → WP/Woo browser cookies for WebView SSO. POST for fetch, GET+redirect for iOS WKWebView, plus one-time login codes so the app never puts a JWT in a URL and never hits the wp-login captcha.
 * Version: 1.2.0
 * Author: Qtoys
 *
 * Deploy this file to wp-content/plugins/qtoys-jwt-cookie-bridge/qtoys-jwt-cookie-bridge.php
 * and activate in WordPress admin. Required for My Account / checkout WebView SSO.
 */

if (!defined('ABSPATH')) {
    exit;
}

add_action('rest_api_init', function () {
    register_rest_route('qtoys/v1', '/mobile-session', [
        [
            'methods'             => 'POST',
            'callback'            => 'qtoys_jwt_cookie_bridge_post_callback',
            'permission_callback' => '__return_true',
        ],
        [
            'methods'             => 'GET',
            'callback'            => 'qtoys_jwt_cookie_bridge_get_callback',
            'permission_callback' => '__return_true',
        ],
    ]);

    register_rest_route('qtoys/v1', '/mobile-session/code', [
        'methods'             => 'POST',
        'callback'            => 'qtoys_jwt_cookie_bridge_mint_code_callback',
        'permission_callback' => '__return_true',
    ]);
});

const QTOYS_MS_CODE_TTL       = 300;
const QTOYS_MS_CODE_TRANSIENT = 'qtoys_ms_code_';

function qtoys_jwt_cookie_bridge_mint_code_callback(WP_REST_Request $request) {
    $token = qtoys_jwt_cookie_bridge_token_from_bearer_header($request);
    if ($token === '') {
        return qtoys_jwt_cookie_bridge_error_response('Missing Bearer token', 401);
    }

    $user_id = qtoys_jwt_cookie_bridge_resolve_user_id_from_token($token);
    if (!$user_id) {
        return qtoys_jwt_cookie_bridge_error_response('Token invalid', 401);
    }

    $code = bin2hex(random_bytes(24));
    set_transient(
        QTOYS_MS_CODE_TRANSIENT . hash('sha256', $code),
        (int) $user_id,
        QTOYS_MS_CODE_TTL
    );

    return new WP_REST_Response([
        'success'    => true,
        'code'       => $code,
        'expires_in' => QTOYS_MS_CODE_TTL,
    ], 200);
}

function qtoys_jwt_cookie_bridge_resolve_user_id_from_code($code) {
    $code = trim((string) $code);
    if ($code === '') {
        return 0;
    }
    $key     = QTOYS_MS_CODE_TRANSIENT . hash('sha256', $code);
    $user_id = get_transient($key);
    if ($user_id === false) {
        return 0;
    }
    delete_transient($key);
    return (int) $user_id;
}

function qtoys_jwt_cookie_bridge_post_callback(WP_REST_Request $request) {
    $token = qtoys_jwt_cookie_bridge_token_from_bearer_header($request);
    if ($token === '') {
        return qtoys_jwt_cookie_bridge_error_response('Missing Bearer token', 401);
    }

    $user_id = qtoys_jwt_cookie_bridge_resolve_user_id_from_token($token);
    if (!$user_id) {
        return qtoys_jwt_cookie_bridge_error_response('Token invalid', 401);
    }

    $user = qtoys_jwt_cookie_bridge_establish_session($user_id);
    if (!$user) {
        return qtoys_jwt_cookie_bridge_error_response('User not found', 401);
    }

    return new WP_REST_Response([
        'success' => true,
        'user_id' => $user->ID,
        'message' => 'Web session cookies established',
    ], 200);
}

function qtoys_jwt_cookie_bridge_callback(WP_REST_Request $request) {
    return qtoys_jwt_cookie_bridge_post_callback($request);
}

function qtoys_jwt_cookie_bridge_get_callback(WP_REST_Request $request) {
    $code    = (string) ($request->get_param('code') ?? '');
    $user_id = 0;
    if ($code !== '') {
        $user_id = qtoys_jwt_cookie_bridge_resolve_user_id_from_code($code);
        if (!$user_id) {
            return qtoys_jwt_cookie_bridge_error_response('Code invalid or expired', 401);
        }
    } else {
        $token = qtoys_jwt_cookie_bridge_token_from_query($request);
        if ($token === '') {
            return qtoys_jwt_cookie_bridge_error_response('Missing code/token', 401);
        }
        $user_id = qtoys_jwt_cookie_bridge_resolve_user_id_from_token($token);
        if (!$user_id) {
            return qtoys_jwt_cookie_bridge_error_response('Token invalid', 401);
        }
    }

    $user = qtoys_jwt_cookie_bridge_establish_session($user_id);
    if (!$user) {
        return qtoys_jwt_cookie_bridge_error_response('User not found', 401);
    }

    $redirect = $request->get_param('redirect_to')
        ?: $request->get_param('redirect')
        ?: $request->get_param('redirectUrl')
        ?: home_url('/my-account/');

    $redirect = esc_url_raw($redirect);
    if (!$redirect || !wp_http_validate_url($redirect)) {
        $redirect = home_url('/my-account/');
    }

    wp_safe_redirect($redirect);
    exit;
}

function qtoys_jwt_cookie_bridge_error_response($message, $status) {
    return new WP_REST_Response([
        'success' => false,
        'message' => $message,
    ], $status);
}

function qtoys_jwt_cookie_bridge_token_from_bearer_header(WP_REST_Request $request) {
    $auth = $request->get_header('authorization');
    if (!$auth || stripos($auth, 'Bearer ') !== 0) {
        return '';
    }
    return trim(substr($auth, 7));
}

function qtoys_jwt_cookie_bridge_token_from_query(WP_REST_Request $request) {
    $token = $request->get_param('token');
    return $token ? trim((string) $token) : '';
}

function qtoys_jwt_cookie_bridge_resolve_user_id_from_token($token) {
    $token = trim((string) $token);
    if ($token === '') {
        return 0;
    }

    $validate_url = rest_url('jwt-auth/v1/token/validate');
    $resp = wp_remote_post($validate_url, [
        'headers' => [
            'Authorization' => 'Bearer ' . $token,
            'Accept'        => 'application/json',
        ],
        'timeout' => 10,
    ]);

    if (is_wp_error($resp)) {
        return 0;
    }

    $status = wp_remote_retrieve_response_code($resp);
    if ($status < 200 || $status >= 300) {
        return 0;
    }

    $parts = explode('.', $token);
    if (count($parts) !== 3) {
        return 0;
    }

    $payload_json = qtoys_jwt_cookie_bridge_base64url_decode($parts[1]);
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

function qtoys_jwt_cookie_bridge_establish_session($user_id) {
    $user_id = (int) $user_id;
    if ($user_id <= 0) {
        return null;
    }

    $user = get_user_by('id', $user_id);
    if (!$user || !$user->ID) {
        return null;
    }

    wp_set_current_user($user->ID);
    wp_set_auth_cookie($user->ID, true, is_ssl());
    do_action('wp_login', $user->user_login, $user);

    if (function_exists('WC') && WC()->session) {
        WC()->session->set_customer_session_cookie(true);
    }

    return $user;
}

function qtoys_jwt_cookie_bridge_base64url_decode($data) {
    $remainder = strlen($data) % 4;
    if ($remainder) {
        $data .= str_repeat('=', 4 - $remainder);
    }
    return base64_decode(strtr($data, '-_', '+/'));
}
