import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';

const verifyEmailMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		verifyEmail: verifyEmailMock
	}))
}));

import { load } from './+page.server';

describe('Verify email load', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('returns success with backend message when token verification succeeds', async () => {
		verifyEmailMock.mockResolvedValue({ message: 'Email verified successfully' });

		const result = await load({ params: { token: 'verify-token-abc' } } as never);
		expect(result).toEqual({
			success: true,
			message: 'Email verified successfully'
		});
		expect(verifyEmailMock).toHaveBeenCalledWith({ token: 'verify-token-abc' });
	});

	it('returns backend error message when API rejects token', async () => {
		verifyEmailMock.mockRejectedValue(new ApiRequestError(400, 'verification token expired'));

		const result = await load({ params: { token: 'expired-token' } } as never);
		expect(result).toEqual({
			success: false,
			message: 'verification token expired'
		});
	});

	it('returns actionable message when auth API is unreachable', async () => {
		verifyEmailMock.mockRejectedValue(new TypeError('fetch failed'));

		const result = await load({ params: { token: 'network-fail-token' } } as never);
		expect(result).toEqual({
			success: false,
			message: 'Authentication service is unavailable. Please verify API_URL and try again.'
		});
	});
});
