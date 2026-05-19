import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import { AUTH_COOKIE, COOKIE_MAX_AGE } from '$lib/config';
import { createHmac } from 'node:crypto';

const loginMock = vi.fn();

// $env/dynamic/private is provided by @sveltejs/kit's Vite plugin and does NOT
// read process.env at call time in vitest — mutating process.env after import
// has no effect on env.API_BASE_URL. Stub it explicitly per the established
// repo pattern (see web/src/hooks.server.test.ts and the admin/* test files).
vi.mock('$env/dynamic/private', () => ({
	env: {
		API_BASE_URL: 'http://127.0.0.1:3001',
		JWT_SECRET: 'jwt-secret-for-tests-1234567890'
	}
}));

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		login: loginMock
	}))
}));

import { actions, load, prerender as loginPrerender } from './+page.server';

const TEST_JWT_SECRET = 'jwt-secret-for-tests-1234567890';

function b64UrlEncodeJson(value: Record<string, unknown>): string {
	return Buffer.from(JSON.stringify(value))
		.toString('base64')
		.replace(/\+/g, '-')
		.replace(/\//g, '_')
		.replace(/=+$/, '');
}

function makeJwt(payload: Record<string, unknown>, secret = TEST_JWT_SECRET): string {
	const header = b64UrlEncodeJson({ alg: 'HS256', typ: 'JWT' });
	const body = b64UrlEncodeJson(payload);
	const signature = createHmac('sha256', secret)
		.update(`${header}.${body}`)
		.digest('base64')
		.replace(/\+/g, '-')
		.replace(/\//g, '_')
		.replace(/=+$/, '');
	return `${header}.${body}.${signature}`;
}

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

describe('Login server load', () => {
	it('returns apiBaseUrl from getApiBaseUrl()', async () => {
		// The hoisted vi.mock above stubs $env/dynamic/private with
		// API_BASE_URL='http://127.0.0.1:3001'; this test verifies load() wires
		// through to getApiBaseUrl() rather than fabricating a value of its own.
		await expect(load({} as never)).resolves.toEqual({ apiBaseUrl: 'http://127.0.0.1:3001' });
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
		const validToken = makeJwt({ sub: 'customer-123', exp: 9999999999, iat: 1000 });
		loginMock.mockResolvedValue({ token: validToken });

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
			validToken,
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
		const validToken = makeJwt({ sub: 'customer-123', exp: 9999999999, iat: 1000 });
		loginMock.mockResolvedValue({ token: validToken });

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
			validToken,
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

	it('fails closed when the returned auth token cannot establish a dashboard session', async () => {
		const setCookie = vi.fn();
		loginMock.mockResolvedValue({ token: 'not-a-jwt' });

		const result = await actions.default(
			makeEvent({ email: 'User@Example.COM', password: 'password123' }, setCookie)
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 503,
				data: {
					errors: {
						form: 'Authentication session could not be established. Please verify JWT_SECRET and try again.'
					},
					email: 'user@example.com'
				}
			})
		);
		expect(setCookie).not.toHaveBeenCalled();
	});
});
