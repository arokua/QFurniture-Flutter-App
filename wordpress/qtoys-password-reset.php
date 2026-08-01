<?php
/**
 * Plugin Name: Qtoys Password Reset (Native App)
 * Description: Native password reset endpoints for the Qtoys mobile app. Emails a short-lived single-use code and exchanges it for a new password, with no storefront redirect.
 * Version:     1.0.0
 * Author:      Qtoys
 *
 * Endpoints (namespace qtoys/v1):
 *   POST /password-reset/request  { email }
 *        Always 200 with an identical body, so the response cannot be used to
 *        discover which addresses have accounts.
 *   POST /password-reset/confirm  { email, code, password }
 *        -> { success: true, token?: "<jwt>" }
 *
 * Both routes are intentionally public (the caller is by definition logged
 * out). Everything that would normally be an auth check is therefore done as
 * rate limiting, a short TTL, and single-use codes.
 *
 * NOTE: Cloudflare must allow POST to /wp-json/qtoys/v1/* — it otherwise
 * answers 403 before WordPress runs.
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

/*
 * Every constant and function below is guarded. Two copies of a Qtoys plugin
 * being active at once has already taken this site down once with a
 * "Cannot redeclare" fatal (see localDocs/deferred-backlog.txt B1).
 */

if ( ! defined( 'QTOYS_PR_CODE_TTL' ) ) {
	define( 'QTOYS_PR_CODE_TTL', 15 * MINUTE_IN_SECONDS );
}
if ( ! defined( 'QTOYS_PR_MAX_VERIFY_ATTEMPTS' ) ) {
	define( 'QTOYS_PR_MAX_VERIFY_ATTEMPTS', 5 );
}
if ( ! defined( 'QTOYS_PR_META_KEY' ) ) {
	define( 'QTOYS_PR_META_KEY', '_qtoys_pr_code' );
}
if ( ! defined( 'QTOYS_PR_MIN_PASSWORD' ) ) {
	// Mirrors PasswordPolicy.minLength in the app. Re-checked here because a
	// client is never authoritative about its own validation.
	define( 'QTOYS_PR_MIN_PASSWORD', 10 );
}

if ( ! function_exists( 'qtoys_pr_register_routes' ) ) {
	/**
	 * Public by necessity, but with declared, sanitised and validated args.
	 */
	function qtoys_pr_register_routes() {
		register_rest_route(
			'qtoys/v1',
			'/password-reset/request',
			array(
				'methods'             => WP_REST_Server::CREATABLE,
				'callback'            => 'qtoys_pr_handle_request',
				'permission_callback' => '__return_true',
				'args'                => array(
					'email' => array(
						'required'          => true,
						'type'              => 'string',
						'sanitize_callback' => 'sanitize_text_field',
						'validate_callback' => function ( $value ) {
							return is_string( $value ) && strlen( $value ) <= 254;
						},
					),
				),
			)
		);

		register_rest_route(
			'qtoys/v1',
			'/password-reset/confirm',
			array(
				'methods'             => WP_REST_Server::CREATABLE,
				'callback'            => 'qtoys_pr_handle_confirm',
				'permission_callback' => '__return_true',
				'args'                => array(
					'email'    => array(
						'required'          => true,
						'type'              => 'string',
						'sanitize_callback' => 'sanitize_text_field',
					),
					'code'     => array(
						'required'          => true,
						'type'              => 'string',
						'sanitize_callback' => 'sanitize_text_field',
						'validate_callback' => function ( $value ) {
							return is_string( $value ) && preg_match( '/^\d{6}$/', $value );
						},
					),
					'password' => array(
						'required'          => true,
						'type'              => 'string',
						// Deliberately NOT sanitised: stripping characters would
						// silently store a different password than the user typed.
						'validate_callback' => function ( $value ) {
							return is_string( $value )
								&& strlen( $value ) >= QTOYS_PR_MIN_PASSWORD
								&& strlen( $value ) <= 128;
						},
					),
				),
			)
		);
	}
	add_action( 'rest_api_init', 'qtoys_pr_register_routes' );
}

if ( ! function_exists( 'qtoys_pr_client_ip' ) ) {
	function qtoys_pr_client_ip() {
		// Cloudflare fronts this site, so its header is the only trustworthy
		// source; REMOTE_ADDR is the edge node.
		if ( ! empty( $_SERVER['HTTP_CF_CONNECTING_IP'] ) ) {
			return sanitize_text_field( wp_unslash( $_SERVER['HTTP_CF_CONNECTING_IP'] ) );
		}
		if ( ! empty( $_SERVER['REMOTE_ADDR'] ) ) {
			return sanitize_text_field( wp_unslash( $_SERVER['REMOTE_ADDR'] ) );
		}
		return 'unknown';
	}
}

if ( ! function_exists( 'qtoys_pr_throttle' ) ) {
	/**
	 * Fixed-window counter in a transient.
	 *
	 * @return bool True when the caller is over the limit.
	 */
	function qtoys_pr_throttle( $bucket, $key, $limit, $window ) {
		$transient = 'qtoys_pr_' . $bucket . '_' . md5( strtolower( $key ) );
		$count     = (int) get_transient( $transient );
		if ( $count >= $limit ) {
			return true;
		}
		set_transient( $transient, $count + 1, $window );
		return false;
	}
}

if ( ! function_exists( 'qtoys_pr_rate_limited_response' ) ) {
	function qtoys_pr_rate_limited_response() {
		$response = new WP_REST_Response(
			array(
				'success' => false,
				'code'    => 'qtoys_reset_rate_limited',
				'message' => 'Too many attempts. Please try again shortly.',
			),
			429
		);
		$response->header( 'Retry-After', (string) ( 15 * MINUTE_IN_SECONDS ) );
		return $response;
	}
}

if ( ! function_exists( 'qtoys_pr_is_privileged' ) ) {
	/**
	 * Accounts whose password the app must never change.
	 *
	 * Administrators do not sign in to the app, so there is no legitimate flow
	 * to lose here — only the most valuable account on the store to gain if any
	 * part of this plugin is ever wrong. Checked by capability as well as role
	 * name, so a custom high-privilege role is covered too.
	 */
	function qtoys_pr_is_privileged( $user ) {
		if ( ! $user || empty( $user->ID ) ) {
			return true; // Fail closed.
		}
		if ( in_array( 'administrator', (array) $user->roles, true ) ) {
			return true;
		}
		return user_can( $user, 'manage_options' ) || user_can( $user, 'edit_users' );
	}
}

if ( ! function_exists( 'qtoys_pr_privileged_blocked_response' ) ) {
	function qtoys_pr_privileged_blocked_response() {
		return new WP_REST_Response(
			array(
				'success' => false,
				'code'    => 'qtoys_privileged_account',
				'message' => 'For security, this account\'s password has to be changed on the website.',
			),
			403
		);
	}
}

if ( ! function_exists( 'qtoys_pr_handle_request' ) ) {
	/**
	 * Emails a 6-digit code.
	 *
	 * Always answers 200 with the same body whether or not the address exists.
	 * Anything else turns this endpoint into an account-enumeration oracle.
	 */
	function qtoys_pr_handle_request( WP_REST_Request $request ) {
		$email = trim( (string) $request->get_param( 'email' ) );

		if ( qtoys_pr_throttle( 'req_ip', qtoys_pr_client_ip(), 12, HOUR_IN_SECONDS )
			|| qtoys_pr_throttle( 'req_mail', $email, 5, HOUR_IN_SECONDS ) ) {
			return qtoys_pr_rate_limited_response();
		}

		$generic = new WP_REST_Response(
			array(
				'success' => true,
				'message' => 'If that email has an account, a code has been sent.',
			),
			200
		);

		if ( ! is_email( $email ) ) {
			return $generic;
		}

		$user = get_user_by( 'email', $email );
		if ( ! $user ) {
			// Same shape, same status, no timing giveaway worth chasing here:
			// the expensive path below is dominated by wp_mail, which an
			// attacker cannot observe from the response anyway.
			return $generic;
		}

		if ( qtoys_pr_is_privileged( $user ) ) {
			// Silently send nothing rather than answer differently. A distinct
			// response here would turn this endpoint into an oracle for "which
			// address is an administrator", which is worse than the block is
			// worth. With no code ever issued, confirm can never succeed.
			return $generic;
		}

		$code = str_pad( (string) wp_rand( 0, 999999 ), 6, '0', STR_PAD_LEFT );

		update_user_meta(
			$user->ID,
			QTOYS_PR_META_KEY,
			array(
				// Hashed at rest: the raw code never touches the database.
				'hash'     => wp_hash_password( $code ),
				'expires'  => time() + QTOYS_PR_CODE_TTL,
				'attempts' => 0,
			)
		);

		qtoys_pr_send_email( $user, $code );

		return $generic;
	}
}

if ( ! function_exists( 'qtoys_pr_send_email' ) ) {
	function qtoys_pr_send_email( $user, $code ) {
		$site    = wp_specialchars_decode( get_bloginfo( 'name' ), ENT_QUOTES );
		$minutes = (int) ( QTOYS_PR_CODE_TTL / MINUTE_IN_SECONDS );

		$subject = sprintf( '%s password reset code', $site );
		$message = sprintf(
			"Hi %s,\n\n" .
			"Your %s password reset code is:\n\n    %s\n\n" .
			"Enter it in the app within %d minutes.\n\n" .
			"If you didn't ask to reset your password, you can ignore this email — " .
			"your password has not changed.\n",
			$user->display_name ? $user->display_name : $user->user_login,
			$site,
			$code,
			$minutes
		);

		wp_mail( $user->user_email, $subject, $message );
	}
}

if ( ! function_exists( 'qtoys_pr_invalid_code_response' ) ) {
	/**
	 * One response for wrong, expired, already-used and no-such-account, so the
	 * caller cannot tell which of them happened.
	 */
	function qtoys_pr_invalid_code_response() {
		return new WP_REST_Response(
			array(
				'success' => false,
				'code'    => 'qtoys_reset_invalid_code',
				'message' => 'That code is incorrect or has expired.',
			),
			400
		);
	}
}

if ( ! function_exists( 'qtoys_pr_handle_confirm' ) ) {
	function qtoys_pr_handle_confirm( WP_REST_Request $request ) {
		$email    = trim( (string) $request->get_param( 'email' ) );
		$code     = (string) $request->get_param( 'code' );
		$password = (string) $request->get_param( 'password' );

		if ( qtoys_pr_throttle( 'conf_ip', qtoys_pr_client_ip(), 20, HOUR_IN_SECONDS ) ) {
			return qtoys_pr_rate_limited_response();
		}

		if ( ! is_email( $email ) ) {
			return qtoys_pr_invalid_code_response();
		}

		$user = get_user_by( 'email', $email );
		if ( ! $user ) {
			return qtoys_pr_invalid_code_response();
		}

		// Defence in depth: request never issues a code for these accounts, so
		// this should be unreachable. Deliberately the same indistinguishable
		// response as a bad code, for the same anti-enumeration reason.
		if ( qtoys_pr_is_privileged( $user ) ) {
			return qtoys_pr_invalid_code_response();
		}

		$record = get_user_meta( $user->ID, QTOYS_PR_META_KEY, true );
		if ( ! is_array( $record ) || empty( $record['hash'] ) ) {
			return qtoys_pr_invalid_code_response();
		}

		if ( empty( $record['expires'] ) || time() > (int) $record['expires'] ) {
			delete_user_meta( $user->ID, QTOYS_PR_META_KEY );
			return qtoys_pr_invalid_code_response();
		}

		$attempts = isset( $record['attempts'] ) ? (int) $record['attempts'] : 0;
		if ( $attempts >= QTOYS_PR_MAX_VERIFY_ATTEMPTS ) {
			// Burn the code rather than let it be ground down.
			delete_user_meta( $user->ID, QTOYS_PR_META_KEY );
			return qtoys_pr_invalid_code_response();
		}

		if ( ! wp_check_password( $code, $record['hash'] ) ) {
			$record['attempts'] = $attempts + 1;
			update_user_meta( $user->ID, QTOYS_PR_META_KEY, $record );
			return qtoys_pr_invalid_code_response();
		}

		// Re-check strength server-side; the client's rules are advisory.
		if ( strlen( $password ) < QTOYS_PR_MIN_PASSWORD ) {
			return new WP_REST_Response(
				array(
					'success' => false,
					'code'    => 'qtoys_reset_weak_password',
					'message' => 'Please choose a stronger password.',
				),
				400
			);
		}

		// Single-use: consume the code before the password is changed, so a
		// replay cannot ride on a slow write.
		delete_user_meta( $user->ID, QTOYS_PR_META_KEY );

		reset_password( $user, $password );

		// Anyone holding a stolen session for this account loses it here.
		$sessions = WP_Session_Tokens::get_instance( $user->ID );
		if ( $sessions ) {
			$sessions->destroy_all();
		}

		$payload = array( 'success' => true );

		$token = qtoys_pr_issue_jwt( $user, $password );
		if ( $token ) {
			$payload['token'] = $token;
		}

		return new WP_REST_Response( $payload, 200 );
	}
}

if ( ! function_exists( 'qtoys_pr_issue_jwt' ) ) {
	/**
	 * Mints a JWT so the app can sign the user straight in.
	 *
	 * Dispatched internally through rest_do_request rather than over HTTP: a
	 * loopback request would go back out through Cloudflare, which blocks POST
	 * to /wp-json/* and would fail here for the same reason the app's token
	 * validation does.
	 *
	 * Returns null when the JWT plugin is absent — the app then falls back to a
	 * normal sign-in, so this is a convenience, not a dependency.
	 */
	function qtoys_pr_issue_jwt( $user, $password ) {
		$request = new WP_REST_Request( 'POST', '/jwt-auth/v1/token' );
		$request->set_header( 'Content-Type', 'application/json' );
		$request->set_body_params(
			array(
				'username' => $user->user_login,
				'password' => $password,
			)
		);

		$response = rest_do_request( $request );
		if ( is_wp_error( $response ) || $response->is_error() ) {
			return null;
		}

		$data = $response->get_data();
		if ( is_array( $data ) && ! empty( $data['token'] ) ) {
			return $data['token'];
		}
		// Some builds nest it under `data`.
		if ( is_array( $data ) && ! empty( $data['data']['token'] ) ) {
			return $data['data']['token'];
		}
		return null;
	}
}

/*
 * Signed-in password change.
 *
 * The app previously did this with PUT wc/v3/customers/<id>, which on this site
 * is role-gated ("cannot reset password using this endpoint with role ...").
 * Worse, when the user's own token was refused it retried with the store-wide
 * consumer key — an admin credential rewriting one user's password. This route
 * only ever acts as the caller, and proves possession of the current password
 * first, which the WooCommerce endpoint never did.
 *
 * Registered separately from the reset routes so the two can be reasoned about
 * independently: these require an identity, those cannot have one.
 */
if ( ! function_exists( 'qtoys_pr_register_change_route' ) ) {
	function qtoys_pr_register_change_route() {
		register_rest_route(
			'qtoys/v1',
			'/change-password',
			array(
				'methods'             => WP_REST_Server::CREATABLE,
				'callback'            => 'qtoys_pr_handle_change',
				'permission_callback' => function () {
					return is_user_logged_in();
				},
				'args'                => array(
					'current_password' => array(
						'required' => true,
						'type'     => 'string',
					),
					'password'         => array(
						'required'          => true,
						'type'              => 'string',
						// Not sanitised, for the same reason as the reset route.
						'validate_callback' => function ( $value ) {
							return is_string( $value )
								&& strlen( $value ) >= QTOYS_PR_MIN_PASSWORD
								&& strlen( $value ) <= 128;
						},
					),
				),
			)
		);
	}
	add_action( 'rest_api_init', 'qtoys_pr_register_change_route' );
}

if ( ! function_exists( 'qtoys_pr_handle_change' ) ) {
	function qtoys_pr_handle_change( WP_REST_Request $request ) {
		$user = wp_get_current_user();
		if ( ! $user || ! $user->ID ) {
			return new WP_REST_Response(
				array(
					'success' => false,
					'code'    => 'qtoys_change_not_signed_in',
					'message' => 'Please sign in again.',
				),
				401
			);
		}

		// The caller is already authenticated as themselves here, so a distinct
		// message leaks nothing they do not already know about their own account.
		if ( qtoys_pr_is_privileged( $user ) ) {
			return qtoys_pr_privileged_blocked_response();
		}

		// Per-user, so one account cannot be used to brute-force its own
		// current password, and per-IP as a backstop.
		if ( qtoys_pr_throttle( 'chg_user', (string) $user->ID, 10, HOUR_IN_SECONDS )
			|| qtoys_pr_throttle( 'chg_ip', qtoys_pr_client_ip(), 30, HOUR_IN_SECONDS ) ) {
			return qtoys_pr_rate_limited_response();
		}

		$current  = (string) $request->get_param( 'current_password' );
		$password = (string) $request->get_param( 'password' );

		if ( ! wp_check_password( $current, $user->user_pass, $user->ID ) ) {
			return new WP_REST_Response(
				array(
					'success' => false,
					'code'    => 'qtoys_change_wrong_password',
					'message' => 'That current password is not correct.',
				),
				400
			);
		}

		if ( strlen( $password ) < QTOYS_PR_MIN_PASSWORD ) {
			return new WP_REST_Response(
				array(
					'success' => false,
					'code'    => 'qtoys_reset_weak_password',
					'message' => 'Please choose a stronger password.',
				),
				400
			);
		}

		reset_password( $user, $password );

		/*
		 * Deliberately NOT destroying sessions here, unlike the reset route.
		 * A reset is "I lost control of this account, evict everyone"; a
		 * voluntary change is not, and tearing down the caller's own session
		 * would sign the app out at the moment the change succeeded.
		 */

		return new WP_REST_Response( array( 'success' => true ), 200 );
	}
}
