import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import { AUTH_COOKIE, COOKIE_MAX_AGE } from '$lib/config';

const registerMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		register: registerMock
	}))
}));

import { actions } from './+page.server';

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
		url: new URL(url)
	} as never;
}

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
						password: 'Password is required',
						beta_acknowledgement: 'Please acknowledge the public beta terms before signing up.'
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
				confirm_password: 'different',
				beta_acknowledged: 'on'
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
		registerMock.mockResolvedValue({ token: 'signup-jwt-token' });

		await expect(
			actions.default(
				makeEvent(
					{
						name: '  Alice Example  ',
						email: '  ALICE@Example.COM  ',
						password: 'password123',
						confirm_password: 'password123',
						beta_acknowledged: 'on'
					},
					setCookie
				)
			)
		).rejects.toMatchObject({ status: 303, location: '/dashboard' });

		expect(registerMock).toHaveBeenCalledWith({
			name: 'Alice Example',
			email: 'alice@example.com',
			password: 'password123'
		});
		expect(setCookie).toHaveBeenCalledWith(
			AUTH_COOKIE,
			'signup-jwt-token',
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
		registerMock.mockResolvedValue({ token: 'signup-jwt-token' });

		await expect(
			actions.default(
				makeEvent(
					{
						name: 'Alice Example',
						email: 'alice@example.com',
						password: 'password123',
						confirm_password: 'password123',
						beta_acknowledged: 'on'
					},
					setCookie,
					'http://127.0.0.1:5173/signup'
				)
			)
		).rejects.toMatchObject({ status: 303, location: '/dashboard' });

		expect(setCookie).toHaveBeenCalledWith(
			AUTH_COOKIE,
			'signup-jwt-token',
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
				confirm_password: 'password123',
				beta_acknowledged: 'on'
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
				confirm_password: 'password123',
				beta_acknowledged: 'on'
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

	it('fails before calling the API when public beta acknowledgement is missing', async () => {
		const result = await actions.default(
			makeEvent({
				name: 'Alice',
				email: 'alice@example.com',
				password: 'password123',
				confirm_password: 'password123'
			})
		);

		expect(registerMock).not.toHaveBeenCalled();
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: {
					errors: {
						beta_acknowledgement: 'Please acknowledge the public beta terms before signing up.'
					},
					name: 'Alice',
					email: 'alice@example.com'
				}
			})
		);
	});
});
