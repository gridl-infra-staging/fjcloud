import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';

const resetPasswordMock = vi.fn();
const VALID_PASSWORD = 'ValidPassword123!';
const MULTIBYTE_SHORT_PASSWORD = '🔒🔒🔒';

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

function makeEvent(data: Record<string, string> | FormData, token = 'reset-token-123') {
	return {
		request: { formData: async () => (data instanceof FormData ? data : toFormData(data)) },
		params: { token }
	} as never;
}

describe('Reset password server action', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('fails with 400 when password is missing', async () => {
		const result = await actions.default(makeEvent({ password: '', confirm_password: '' }));
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

	it('fails with 400 without calling the API for file-valued password fields', async () => {
		const data = new FormData();
		data.set('password', new Blob(['not-a-string']), 'password.txt');
		data.set('confirm_password', new Blob(['not-a-string']), 'confirmation.txt');

		const result = await actions.default(makeEvent(data));

		expect(resetPasswordMock).not.toHaveBeenCalled();
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: {
					errors: { password: 'Password is required' }
				}
			})
		);
	});

	it('fails with 400 for multi-byte short password and mismatch', async () => {
		const result = await actions.default(
			makeEvent({ password: MULTIBYTE_SHORT_PASSWORD, confirm_password: 'different' })
		);
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: {
					errors: {
						password: 'Password must be at least 15 characters',
						confirm_password: 'Passwords do not match'
					}
				}
			})
		);
	});

	it('calls API with route token and returns success when valid', async () => {
		resetPasswordMock.mockResolvedValue(undefined);

		const result = await actions.default(
			makeEvent({ password: VALID_PASSWORD, confirm_password: VALID_PASSWORD }, 'route-token-xyz')
		);

		expect(result).toEqual({ success: true });
		expect(resetPasswordMock).toHaveBeenCalledWith({
			token: 'route-token-xyz',
			new_password: VALID_PASSWORD
		});
	});

	it('returns API status + message when backend rejects token', async () => {
		resetPasswordMock.mockRejectedValue(new ApiRequestError(400, 'token expired'));

		const result = await actions.default(
			makeEvent({ password: VALID_PASSWORD, confirm_password: VALID_PASSWORD })
		);
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					errors: { form: 'token expired' },
					recoveryAction: 'invalid_or_expired_token'
				})
			})
		);
	});

	it('returns service unavailable when auth API is unreachable', async () => {
		resetPasswordMock.mockRejectedValue(new TypeError('fetch failed'));

		const result = await actions.default(
			makeEvent({ password: VALID_PASSWORD, confirm_password: VALID_PASSWORD })
		);
		expect(result).toEqual(
			expect.objectContaining({
				status: 503,
				data: expect.objectContaining({
					errors: {
						form: 'Authentication service is unavailable. Please verify API_URL and try again.'
					}
				})
			})
		);
	});

	it('keeps backend password validation on the password field', async () => {
		resetPasswordMock.mockRejectedValue(
			new ApiRequestError(400, 'password is too common; choose another password')
		);

		const result = await actions.default(
			makeEvent({ password: VALID_PASSWORD, confirm_password: VALID_PASSWORD })
		);
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: {
					errors: {
						password: 'Password is too common; choose another password'
					}
				}
			})
		);
	});

	it('does not attach a resend-email recovery action to generic reset-submit failures', async () => {
		resetPasswordMock.mockRejectedValue(
			new ApiRequestError(503, 'password reset email temporarily unavailable')
		);

		const result = await actions.default(
			makeEvent({ password: VALID_PASSWORD, confirm_password: VALID_PASSWORD })
		);
		expect(result).toEqual(
			expect.objectContaining({
				status: 503,
				data: {
					errors: {
						form: 'password reset email temporarily unavailable'
					}
				}
			})
		);
		expect(result).not.toEqual(
			expect.objectContaining({
				data: expect.objectContaining({
					recoveryAction: 'request_new_email'
				})
			})
		);
	});
});
