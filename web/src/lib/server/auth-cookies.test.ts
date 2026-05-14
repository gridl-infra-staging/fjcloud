import { describe, expect, it } from 'vitest';
import { authCookieOptions, oauthStateCookieOptions } from './auth-cookies';

describe('authCookieOptions', () => {
	it('marks cookies secure for https requests', () => {
		expect(authCookieOptions(new URL('https://app.example.com/login'), 3600)).toEqual(
			expect.objectContaining({
				path: '/',
				httpOnly: true,
				secure: true,
				sameSite: 'lax',
				maxAge: 3600
			})
		);
	});

	it('marks cookies non-secure for local http requests', () => {
		expect(authCookieOptions(new URL('http://127.0.0.1:5173/login'), 3600)).toEqual(
			expect.objectContaining({
				secure: false
			})
		);
	});
});

describe('oauthStateCookieOptions', () => {
	it('matches oauth_state cookie attributes for flapjack cloud hosts', () => {
		expect(oauthStateCookieOptions(new URL('https://cloud.flapjack.foo/login'))).toEqual(
			expect.objectContaining({
				path: '/',
				httpOnly: true,
				secure: true,
				sameSite: 'none',
				domain: '.flapjack.foo'
			})
		);
	});

	it('omits domain for localhost development hosts', () => {
		expect(
			oauthStateCookieOptions(new URL('http://127.0.0.1:5173/oauth/callback/google'))
		).toEqual(
			expect.objectContaining({
				path: '/',
				secure: false,
				sameSite: 'lax'
			})
		);
	});
});
