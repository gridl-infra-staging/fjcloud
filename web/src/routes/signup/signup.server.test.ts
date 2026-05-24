import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import { AUTH_COOKIE, COOKIE_MAX_AGE } from '$lib/config';
import { createHmac } from 'node:crypto';

const registerMock = vi.fn();

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
	createApiClientForBaseUrl: vi.fn(() => ({
		register: registerMock
	}))
}));

import { actions, load } from './+page.server';

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
	url = 'https://example.com/signup'
) {
	return {
		request: { formData: async () => toFormData(data) },
		cookies: { set: setCookie },
		url: new URL(url),
		locals: { apiBaseUrl: 'http://127.0.0.1:3001' }
	} as never;
}

describe('Signup server load', () => {
	it('returns apiBaseUrl from locals', async () => {
		const event = { locals: { apiBaseUrl: 'http://127.0.0.1:3001' } };
		await expect(load(event as never)).resolves.toEqual({ apiBaseUrl: 'http://127.0.0.1:3001' });
	});
});

describe('Signup server action', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('fails with 400 when required fields are missing', async () => {
		const result = await actions.default(
			makeEvent({ name: '', email: '', password: '', confirm_password: '' })
		);
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: {
					errors: {
						name: 'Name is required',
						email: 'Email is required',
						password: 'Password is required'
					},
					name: '',
					email: ''
				}
			})
		);
	});

	it('fails with 400 for invalid email, short password, and mismatch', async () => {
		const result = await actions.default(
			makeEvent({
				name: 'Alice',
				email: 'not-an-email',
				password: 'short',
				confirm_password: 'different'
			})
		);
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: {
					errors: {
						email: 'Invalid email address',
						password: 'Password must be at least 8 characters',
						confirm_password: 'Passwords do not match'
					},
					name: 'Alice',
					email: 'not-an-email'
				}
			})
		);
	});

	it('normalizes inputs, sets auth cookie, and redirects on successful signup', async () => {
		const setCookie = vi.fn();
		const validToken = makeJwt({ sub: 'customer-123', exp: 9999999999, iat: 1000 });
		registerMock.mockResolvedValue({ token: validToken });

		await expect(
			actions.default(
				makeEvent(
					{
						name: '  Alice Example  ',
						email: '  ALICE@Example.COM  ',
						password: 'password123',
						confirm_password: 'password123'
					},
					setCookie
				)
			)
		).rejects.toMatchObject({ status: 303, location: '/console' });

		expect(registerMock).toHaveBeenCalledWith({
			name: 'Alice Example',
			email: 'alice@example.com',
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

	it('uses a non-secure auth cookie for local http signup flows', async () => {
		const setCookie = vi.fn();
		const validToken = makeJwt({ sub: 'customer-123', exp: 9999999999, iat: 1000 });
		registerMock.mockResolvedValue({ token: validToken });

		await expect(
			actions.default(
				makeEvent(
					{
						name: 'Alice Example',
						email: 'alice@example.com',
						password: 'password123',
						confirm_password: 'password123'
					},
					setCookie,
					'http://127.0.0.1:5173/signup'
				)
			)
		).rejects.toMatchObject({ status: 303, location: '/console' });

		expect(setCookie).toHaveBeenCalledWith(
			AUTH_COOKIE,
			validToken,
			expect.objectContaining({
				secure: false
			})
		);
	});

	it('returns API status + message when backend rejects signup', async () => {
		registerMock.mockRejectedValue(new ApiRequestError(409, 'email already exists'));

		const result = await actions.default(
			makeEvent({
				name: 'Alice',
				email: 'alice@example.com',
				password: 'password123',
				confirm_password: 'password123'
			})
		);
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: {
					errors: {
						form: 'We could not create your account. Please check your details and try again.'
					},
					name: 'Alice',
					email: 'alice@example.com'
				}
			})
		);
	});

	it('returns a service-unavailable error when auth API is unreachable', async () => {
		registerMock.mockRejectedValue(new TypeError('fetch failed'));

		const result = await actions.default(
			makeEvent({
				name: 'Alice',
				email: 'alice@example.com',
				password: 'password123',
				confirm_password: 'password123'
			})
		);
		expect(result).toEqual(
			expect.objectContaining({
				status: 503,
				data: {
					errors: {
						form: 'Authentication service is unavailable. Please verify API_URL and try again.'
					},
					name: 'Alice',
					email: 'alice@example.com'
				}
			})
		);
	});

	it('signs up without requiring beta acknowledgement', async () => {
		const validToken = makeJwt({ sub: 'customer-123', exp: 9999999999, iat: 1000 });
		registerMock.mockResolvedValue({ token: validToken });

		await expect(
			actions.default(
				makeEvent({
					name: 'Alice',
					email: 'alice@example.com',
					password: 'password123',
					confirm_password: 'password123'
				})
			)
		).rejects.toMatchObject({ status: 303, location: '/console' });

		expect(registerMock).toHaveBeenCalledWith({
			name: 'Alice',
			email: 'alice@example.com',
			password: 'password123'
		});
	});

	// Regression test for the JWT-verify asymmetry the Lane 4 launch-verification
	// run surfaced on 2026-05-21: signup was setting the auth cookie and
	// redirecting to /console without verifying the returned token against
	// this runtime's JWT_SECRET, so a cross-env API_BASE_URL (or any JWT_SECRET
	// drift) silently set a dead cookie. Login already had this gate; signup
	// must match. See web/src/routes/login/+page.server.ts and the symmetric
	// "fails closed when the returned auth token cannot establish a dashboard
	// session" test in login.server.test.ts.
	it('fails closed when the returned auth token cannot establish a dashboard session', async () => {
		const setCookie = vi.fn();
		registerMock.mockResolvedValue({ token: 'not-a-jwt' });

		const result = await actions.default(
			makeEvent(
				{
					name: 'Alice',
					email: 'User@Example.COM',
					password: 'password123',
					confirm_password: 'password123'
				},
				setCookie
			)
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 503,
				data: {
					errors: {
						form: 'Authentication session could not be established. Please verify JWT_SECRET and try again.'
					},
					name: 'Alice',
					email: 'user@example.com'
				}
			})
		);
		expect(setCookie).not.toHaveBeenCalled();
	});

	it('still fails before calling the API when required fields are missing', async () => {
		const result = await actions.default(
			makeEvent({
				name: 'Alice',
				email: 'alice@example.com',
				password: '',
				confirm_password: ''
			})
		);

		expect(registerMock).not.toHaveBeenCalled();
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: {
					errors: {
						password: 'Password is required'
					},
					name: 'Alice',
					email: 'alice@example.com'
				}
			})
		);
	});
});
