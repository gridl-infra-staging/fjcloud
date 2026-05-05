import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';

const resendVerificationMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		resendVerification: resendVerificationMock
	}))
}));

import { POST } from './+server';

function makeEvent() {
	return {
		request: new Request('http://localhost/dashboard/resend-verification', {
			method: 'POST'
		}),
		locals: {
			user: { token: 'jwt-token' }
		}
	} as never;
}

describe('POST /dashboard/resend-verification', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('returns 200 success payload from API client', async () => {
		resendVerificationMock.mockResolvedValue({
			message: 'Verification email sent',
			retryAfterSeconds: null
		});

		const response = await POST(makeEvent());

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({
			message: 'Verification email sent',
			retryAfterSeconds: null
		});
	});

	it('passes through backend 400 errors without setting session-expired marker', async () => {
		resendVerificationMock.mockRejectedValue(new ApiRequestError(400, 'email_already_verified'));

		const response = await POST(makeEvent());
		const payload = await response.json();

		expect(response.status).toBe(400);
		expect(payload).toEqual({ error: 'email_already_verified', retryAfterSeconds: null });
		expect(payload._authSessionExpired).toBeUndefined();
	});

	it('passes through backend 429 and Retry-After header', async () => {
		resendVerificationMock.mockRejectedValue(
			new ApiRequestError(429, 'resend_rate_limited', {
				headers: new Headers({ 'Retry-After': '120' })
			})
		);

		const response = await POST(makeEvent());

		expect(response.status).toBe(429);
		expect(response.headers.get('Retry-After')).toBe('120');
		expect(await response.json()).toEqual({
			error: 'resend_rate_limited',
			retryAfterSeconds: 120
		});
	});

	it('maps 401 to the shared dashboard session-expired payload', async () => {
		resendVerificationMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const response = await POST(makeEvent());

		expect(response.status).toBe(401);
		expect(await response.json()).toEqual({
			_authSessionExpired: true,
			error: 'Unauthorized'
		});
	});

	it('maps 403 to the shared dashboard session-expired payload', async () => {
		resendVerificationMock.mockRejectedValue(new ApiRequestError(403, 'Forbidden'));

		const response = await POST(makeEvent());

		expect(response.status).toBe(403);
		expect(await response.json()).toEqual({
			_authSessionExpired: true,
			error: 'Forbidden'
		});
	});
});
