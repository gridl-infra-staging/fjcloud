import { beforeEach, describe, expect, it, vi } from 'vitest';
import { AUTH_COOKIE, COOKIE_MAX_AGE } from '$lib/config';
import { authCookieOptions, oauthStateCookieOptions } from '$lib/server/auth-cookies';

const oauthExchangeMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		oauthExchange: oauthExchangeMock
	}))
}));

import { GET } from './+server';

// Helper now models BOTH OAuth cookies because the API requires both at
// exchange time (Defect-2 browser-binding contract). The callback handler
// must forward whatever subset is present and let the API decide; tests
// here pin that forwarding contract and the cleanup contract.
function makeEvent(options: {
	url: string;
	provider?: string;
	oauthStateCookie?: string | undefined;
	oauthStateBindingCookie?: string | undefined;
	setCookie?: ReturnType<typeof vi.fn>;
	deleteCookie?: ReturnType<typeof vi.fn>;
}) {
	const setCookie = options.setCookie ?? vi.fn();
	const deleteCookie = options.deleteCookie ?? vi.fn();
	const oauthStateCookie = options.oauthStateCookie;
	const oauthStateBindingCookie = options.oauthStateBindingCookie;
	return {
		url: new URL(options.url),
		params: { provider: options.provider ?? 'google' },
		fetch: vi.fn(),
		cookies: {
			get: vi.fn((name: string) => {
				if (name === 'oauth_state') return oauthStateCookie;
				if (name === 'oauth_state_binding') return oauthStateBindingCookie;
				return undefined;
			}),
			set: setCookie,
			delete: deleteCookie
		}
	} as never;
}

describe('oauth callback route', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('forwards both oauth_state and oauth_state_binding cookies to API on success', async () => {
		oauthExchangeMock.mockResolvedValue({
			token: 'oauth-jwt-token',
			customer_id: 'customer-1'
		});
		const setCookie = vi.fn();
		const deleteCookie = vi.fn();
		const callbackUrl = new URL(
			'https://cloud.flapjack.foo/oauth/callback/google?code=oauth-code&state=csrf-state'
		);
		const event = makeEvent({
			url: callbackUrl.toString(),
			oauthStateCookie: 'encrypted-state',
			oauthStateBindingCookie: 'binding-nonce-32',
			setCookie,
			deleteCookie
		});

		await expect(GET(event)).rejects.toMatchObject({ status: 303, location: '/console' });

		// API receives both cookies joined with '; '. The order matters only for
		// readability; cookie parsers are commutative.
		expect(oauthExchangeMock).toHaveBeenCalledWith(
			'google',
			{ code: 'oauth-code', csrf_token: 'csrf-state' },
			'oauth_state=encrypted-state; oauth_state_binding=binding-nonce-32'
		);
		expect(setCookie).toHaveBeenCalledWith(
			AUTH_COOKIE,
			'oauth-jwt-token',
			authCookieOptions(callbackUrl, COOKIE_MAX_AGE)
		);
		// Both cookies must be deleted on success — leaving the binding cookie
		// alive after a successful exchange is dead state that broadens the
		// next-attack window.
		expect(deleteCookie).toHaveBeenCalledWith('oauth_state', oauthStateCookieOptions(callbackUrl));
		expect(deleteCookie).toHaveBeenCalledWith(
			'oauth_state_binding',
			oauthStateCookieOptions(callbackUrl)
		);
	});

	it('redirects to /login?reason=oauth_error on backend failure and clears both cookies', async () => {
		oauthExchangeMock.mockRejectedValue(new Error('oauth failed'));
		const setCookie = vi.fn();
		const deleteCookie = vi.fn();
		const callbackUrl = new URL(
			'https://cloud.flapjack.foo/oauth/callback/google?code=oauth-code&state=csrf-state'
		);
		const event = makeEvent({
			url: callbackUrl.toString(),
			oauthStateCookie: 'encrypted-state',
			oauthStateBindingCookie: 'binding-nonce-32',
			setCookie,
			deleteCookie
		});

		await expect(GET(event)).rejects.toMatchObject({
			status: 303,
			location: '/login?reason=oauth_error'
		});

		expect(setCookie).not.toHaveBeenCalled();
		expect(deleteCookie).toHaveBeenCalledWith('oauth_state', oauthStateCookieOptions(callbackUrl));
		expect(deleteCookie).toHaveBeenCalledWith(
			'oauth_state_binding',
			oauthStateCookieOptions(callbackUrl)
		);
	});

	it('fails safely to oauth_error redirect when callback query params are missing', async () => {
		const setCookie = vi.fn();
		const deleteCookie = vi.fn();
		const callbackUrl = new URL('https://cloud.flapjack.foo/oauth/callback/google?code=oauth-code');
		const event = makeEvent({
			url: callbackUrl.toString(),
			oauthStateCookie: 'encrypted-state',
			oauthStateBindingCookie: 'binding-nonce-32',
			setCookie,
			deleteCookie
		});

		await expect(GET(event)).rejects.toMatchObject({
			status: 303,
			location: '/login?reason=oauth_error'
		});

		expect(oauthExchangeMock).not.toHaveBeenCalled();
		expect(setCookie).not.toHaveBeenCalled();
		expect(deleteCookie).toHaveBeenCalledWith('oauth_state', oauthStateCookieOptions(callbackUrl));
		expect(deleteCookie).toHaveBeenCalledWith(
			'oauth_state_binding',
			oauthStateCookieOptions(callbackUrl)
		);
	});

	it('forwards only oauth_state when binding cookie is absent (lets API return 403)', async () => {
		// Real-world scenario: an attacker drops only the encrypted oauth_state
		// cookie onto a victim's browser. The victim's browser has no binding
		// cookie. The callback should forward what's there and let the API
		// reject with oauth_state_binding_missing — not silently drop the
		// request or fabricate a binding value.
		oauthExchangeMock.mockRejectedValue(new Error('oauth_state_binding_missing'));
		const setCookie = vi.fn();
		const deleteCookie = vi.fn();
		const callbackUrl = new URL(
			'https://cloud.flapjack.foo/oauth/callback/google?code=oauth-code&state=csrf-state'
		);
		const event = makeEvent({
			url: callbackUrl.toString(),
			oauthStateCookie: 'encrypted-state',
			oauthStateBindingCookie: undefined,
			setCookie,
			deleteCookie
		});

		await expect(GET(event)).rejects.toMatchObject({
			status: 303,
			location: '/login?reason=oauth_error'
		});

		expect(oauthExchangeMock).toHaveBeenCalledWith(
			'google',
			{ code: 'oauth-code', csrf_token: 'csrf-state' },
			'oauth_state=encrypted-state'
		);
	});
});
