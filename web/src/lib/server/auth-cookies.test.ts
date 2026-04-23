import { describe, expect, it } from 'vitest';
import { authCookieOptions } from './auth-cookies';

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
