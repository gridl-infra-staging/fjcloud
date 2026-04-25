import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import { AUTH_COOKIE, COOKIE_MAX_AGE } from '$lib/config';

const loginMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		login: loginMock
	}))
}));

import { actions, prerender as loginPrerender } from './+page.server';

function toFormData(entries: Record<string, string>): FormData {
	const fd = new FormData();
	for (const [key, value] of Object.entries(entries)) fd.set(key, value);
	return fd;
}

function makeEvent(
	data: Record<string, string>,
	setCookie = vi.fn(),
	url = 'https://example.com/login'
) {
	return {
		request: { formData: async () => toFormData(data) },
		cookies: { set: setCookie },
		url: new URL(url)
	} as never;
}

describe('login route prerender contract', () => {
	it('opts out of prerender because it defines form actions', () => {
		expect(loginPrerender).toBe(false);
	});
});

describe('Login server action', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('fails with 400 when email and password are missing', async () => {
		const result = await actions.default(makeEvent({ email: '', password: '' }));
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: {
					errors: {
						email: 'Email is required',
						password: 'Password is required'
					},
					email: ''
				}
			})
		);
	});

	it('normalizes email, sets auth cookie, and redirects on successful login', async () => {
		const setCookie = vi.fn();
		loginMock.mockResolvedValue({ token: 'jwt-token' });

		await expect(
			actions.default(
				makeEvent({ email: '  USER@Example.COM  ', password: 'password123' }, setCookie)
			)
		).rejects.toMatchObject({ status: 303, location: '/dashboard' });

		expect(loginMock).toHaveBeenCalledWith({
			email: 'user@example.com',
			password: 'password123'
		});
		expect(setCookie).toHaveBeenCalledWith(
			AUTH_COOKIE,
			'jwt-token',
			expect.objectContaining({
				path: '/',
				httpOnly: true,
				secure: true,
				sameSite: 'lax',
				maxAge: COOKIE_MAX_AGE
			})
		);
	});

	it('uses a non-secure auth cookie for local http login flows', async () => {
		const setCookie = vi.fn();
		loginMock.mockResolvedValue({ token: 'jwt-token' });

		await expect(
			actions.default(
				makeEvent(
					{ email: 'user@example.com', password: 'password123' },
					setCookie,
					'http://127.0.0.1:5173/login'
				)
			)
		).rejects.toMatchObject({ status: 303, location: '/dashboard' });

		expect(setCookie).toHaveBeenCalledWith(
			AUTH_COOKIE,
			'jwt-token',
			expect.objectContaining({
				secure: false
			})
		);
	});

	it('returns API status + message when backend rejects credentials', async () => {
		loginMock.mockRejectedValue(new ApiRequestError(401, 'invalid credentials'));

		const result = await actions.default(
			makeEvent({ email: 'User@Example.COM', password: 'bad-password' })
		);
		expect(result).toEqual(
			expect.objectContaining({
				status: 401,
				data: {
					errors: { form: 'invalid credentials' },
					email: 'user@example.com'
				}
			})
		);
	});

	it('returns a service-unavailable error when auth API is unreachable', async () => {
		loginMock.mockRejectedValue(new TypeError('fetch failed'));

		const result = await actions.default(
			makeEvent({ email: 'User@Example.COM', password: 'password123' })
		);
		expect(result).toEqual(
			expect.objectContaining({
				status: 503,
				data: {
					errors: {
						form: 'Authentication service is unavailable. Please verify API_URL and try again.'
					},
					email: 'user@example.com'
				}
			})
		);
	});
});
