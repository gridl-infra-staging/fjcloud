import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';

const forgotPasswordMock = vi.fn();
const resendPasswordResetMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		forgotPassword: forgotPasswordMock,
		resendPasswordReset: resendPasswordResetMock
	}))
}));

import { actions } from './+page.server';

function toFormData(entries: Record<string, string>): FormData {
	const fd = new FormData();
	for (const [key, value] of Object.entries(entries)) fd.set(key, value);
	return fd;
}

function makeEvent(data: Record<string, string>) {
	return {
		request: { formData: async () => toFormData(data) }
	} as never;
}

describe('Forgot password server action', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('fails with 400 when email is missing', async () => {
		const result = await actions.default(makeEvent({ email: '' }));
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: {
					errors: { email: 'Email is required' },
					email: ''
				}
			})
		);
	});

	it('normalizes email before calling forgotPassword and returns sent=true', async () => {
		forgotPasswordMock.mockResolvedValue(undefined);

		const result = await actions.default(makeEvent({ email: '  USER@Example.COM  ' }));
		expect(result).toEqual({ sent: true, email: 'user@example.com' });
		expect(forgotPasswordMock).toHaveBeenCalledWith({ email: 'user@example.com' });
	});

	it('still returns sent=true when backend returns ApiRequestError', async () => {
		forgotPasswordMock.mockRejectedValue(new ApiRequestError(404, 'customer not found'));

		const result = await actions.default(makeEvent({ email: 'user@example.com' }));
		expect(result).toEqual({ sent: true, email: 'user@example.com' });
	});

	it('still returns sent=true when auth API is unreachable', async () => {
		forgotPasswordMock.mockRejectedValue(new TypeError('fetch failed'));

		const result = await actions.default(makeEvent({ email: 'user@example.com' }));
		expect(result).toEqual({ sent: true, email: 'user@example.com' });
	});

	it('resend action keeps generic resend success even when success payload includes retry-after metadata', async () => {
		resendPasswordResetMock.mockResolvedValue({
			message: 'if an account exists with that email, a password reset link has been sent',
			retryAfterSeconds: 120
		});

		const result = await actions.default(makeEvent({ email: 'user@example.com', intent: 'resend' }));
		expect(result).toEqual({
			sent: true,
			email: 'user@example.com',
			resendStatus: 'resent'
		});
	});

	it('resend action returns explicit delivery-failure form data on resend transport failure', async () => {
		resendPasswordResetMock.mockRejectedValue(new TypeError('fetch failed'));

		const result = await actions.default(makeEvent({ email: 'user@example.com', intent: 'resend' }));
		expect(result).toEqual(
			expect.objectContaining({
				status: 503,
				data: {
					sent: true,
					email: 'user@example.com',
					resendStatus: 'delivery_failure'
				}
			})
		);
	});

	it('resend action returns explicit delivery-failure form data on resend 503 response', async () => {
		resendPasswordResetMock.mockRejectedValue(new ApiRequestError(503, 'auth unavailable'));

		const result = await actions.default(makeEvent({ email: 'user@example.com', intent: 'resend' }));
		expect(result).toEqual(
			expect.objectContaining({
				status: 503,
				data: {
					sent: true,
					email: 'user@example.com',
					resendStatus: 'delivery_failure'
				}
			})
		);
	});

	it('resend action returns cooldown form data on auth middleware 429 with retry-after metadata', async () => {
		resendPasswordResetMock.mockRejectedValue(
			new ApiRequestError(429, 'too many requests', {
				body: { retryAfterSeconds: 90 }
			})
		);

		const result = await actions.default(makeEvent({ email: 'user@example.com', intent: 'resend' }));
		expect(result).toEqual(
			expect.objectContaining({
				status: 429,
				data: {
					sent: true,
					email: 'user@example.com',
					resendStatus: 'cooldown',
					retryAfterSeconds: 90
				}
			})
		);
	});

	it('resend action returns explicit delivery-failure form data on resend non-503 ApiRequestError responses', async () => {
		resendPasswordResetMock.mockRejectedValue(new ApiRequestError(500, 'internal server error'));

		const result = await actions.default(makeEvent({ email: 'user@example.com', intent: 'resend' }));
		expect(result).toEqual(
			expect.objectContaining({
				status: 503,
				data: {
					sent: true,
					email: 'user@example.com',
					resendStatus: 'delivery_failure'
				}
			})
		);
	});
});
