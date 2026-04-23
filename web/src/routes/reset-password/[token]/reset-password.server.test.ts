import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';

const resetPasswordMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		resetPassword: resetPasswordMock
	}))
}));

import { actions } from './+page.server';

function toFormData(entries: Record<string, string>): FormData {
	const fd = new FormData();
	for (const [key, value] of Object.entries(entries)) fd.set(key, value);
	return fd;
}

function makeEvent(data: Record<string, string>, token = 'reset-token-123') {
	return {
		request: { formData: async () => toFormData(data) },
		params: { token }
	} as never;
}

describe('Reset password server action', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('fails with 400 when password is missing', async () => {
		const result = await actions.default(
			makeEvent({ password: '', confirm_password: '' })
		);
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: {
					errors: {
						password: 'Password is required'
					}
				}
			})
		);
	});

	it('fails with 400 for short password and mismatch', async () => {
		const result = await actions.default(
			makeEvent({ password: 'short', confirm_password: 'different' })
		);
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: {
					errors: {
						password: 'Password must be at least 8 characters',
						confirm_password: 'Passwords do not match'
					}
				}
			})
		);
	});

	it('calls API with route token and returns success when valid', async () => {
		resetPasswordMock.mockResolvedValue(undefined);

		const result = await actions.default(
			makeEvent(
				{ password: 'newpassword123', confirm_password: 'newpassword123' },
				'route-token-xyz'
			)
		);

		expect(result).toEqual({ success: true });
		expect(resetPasswordMock).toHaveBeenCalledWith({
			token: 'route-token-xyz',
			new_password: 'newpassword123'
		});
	});

	it('returns API status + message when backend rejects token', async () => {
		resetPasswordMock.mockRejectedValue(new ApiRequestError(400, 'token expired'));

		const result = await actions.default(
			makeEvent({ password: 'newpassword123', confirm_password: 'newpassword123' })
		);
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: {
					errors: { form: 'token expired' }
				}
			})
		);
	});

	it('returns service unavailable when auth API is unreachable', async () => {
		resetPasswordMock.mockRejectedValue(new TypeError('fetch failed'));

		const result = await actions.default(
			makeEvent({ password: 'newpassword123', confirm_password: 'newpassword123' })
		);
		expect(result).toEqual(
			expect.objectContaining({
				status: 503,
				data: {
					errors: {
						form: 'Authentication service is unavailable. Please verify API_URL and try again.'
					}
				}
			})
		);
	});
});
