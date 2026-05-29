/**
 * @module Stub summary for +server.ts.
 */
import { redirect } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { AUTH_COOKIE, COOKIE_MAX_AGE } from '$lib/config';
import { createApiClient } from '$lib/server/api';
import { authCookieOptions, oauthStateCookieOptions } from '$lib/server/auth-cookies';

/**
 * TODO: Document GET.
 */
export const GET: RequestHandler = async ({ params, url, cookies, fetch }) => {
	const code = url.searchParams.get('code');
	const state = url.searchParams.get('state');
	// Both cookies must be forwarded to the API. start_oauth on the API
	// emits oauth_state (encrypted) AND oauth_state_binding (raw nonce that
	// matches the bound_session_id encoded inside the encrypted plaintext).
	// The API exchange endpoint requires both AND that they match — that's
	// the login-fixation defense (DEFECT 2 in the post-merge review).
	// Forwarding only oauth_state would 403 every legitimate login.
	const oauthStateCookie = cookies.get('oauth_state');
	const oauthStateBindingCookie = cookies.get('oauth_state_binding');
	const oauthStateDeleteOptions = oauthStateCookieOptions(url);

	// Both cookies are deleted on every exit path (early redirect, error,
	// success). Stale cookies are useless beyond a single exchange and
	// holding them open broadens the fixation window.
	const clearOAuthCookies = () => {
		cookies.delete('oauth_state', oauthStateDeleteOptions);
		cookies.delete('oauth_state_binding', oauthStateDeleteOptions);
	};

	if (!code || !state) {
		clearOAuthCookies();
		redirect(303, '/login?reason=oauth_error');
	}

	const cookieParts: string[] = [];
	if (oauthStateCookie) cookieParts.push(`oauth_state=${oauthStateCookie}`);
	if (oauthStateBindingCookie) {
		cookieParts.push(`oauth_state_binding=${oauthStateBindingCookie}`);
	}
	const cookieHeader = cookieParts.length > 0 ? cookieParts.join('; ') : undefined;

	let auth: { token: string };
	try {
		const api = createApiClient(undefined, fetch);
		auth = await api.oauthExchange(params.provider, { code, csrf_token: state }, cookieHeader);
	} catch {
		clearOAuthCookies();
		redirect(303, '/login?reason=oauth_error');
	}

	cookies.set(AUTH_COOKIE, auth.token, authCookieOptions(url, COOKIE_MAX_AGE));
	clearOAuthCookies();
	redirect(303, '/console');
};
