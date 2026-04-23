import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';

const forgotPasswordMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		forgotPassword: forgotPasswordMock
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
		expect(result).toEqual({ sent: true });
		expect(forgotPasswordMock).toHaveBeenCalledWith({ email: 'user@example.com' });
	});

	it('still returns sent=true when backend returns ApiRequestError', async () => {
		forgotPasswordMock.mockRejectedValue(new ApiRequestError(404, 'customer not found'));

		const result = await actions.default(makeEvent({ email: 'user@example.com' }));
		expect(result).toEqual({ sent: true });
	});

	it('still returns sent=true when auth API is unreachable', async () => {
		forgotPasswordMock.mockRejectedValue(new TypeError('fetch failed'));

		const result = await actions.default(makeEvent({ email: 'user@example.com' }));
		expect(result).toEqual({ sent: true });
	});
});
