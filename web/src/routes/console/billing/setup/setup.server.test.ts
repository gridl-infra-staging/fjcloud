import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ApiRequestError } from '$lib/api/client';

const createSetupIntentMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		createSetupIntent: createSetupIntentMock
	}))
}));

import { load } from './+page.server';

describe('Billing setup page server load', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('returns billingUnavailable when API responds with service_not_configured', async () => {
		createSetupIntentMock.mockRejectedValue(new ApiRequestError(503, 'service_not_configured'));

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			clientSecret: null,
			error: null,
			billingUnavailable: true
		});
	});

	it('returns billingUnavailable when API responds with no stripe customer linked', async () => {
		createSetupIntentMock.mockRejectedValue(new ApiRequestError(400, 'no stripe customer linked'));

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			clientSecret: null,
			error: null,
			billingUnavailable: true
		});
	});

	it('returns the generic setup error for unrelated failures', async () => {
		createSetupIntentMock.mockRejectedValue(new ApiRequestError(500, 'internal server error'));

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			clientSecret: null,
			error: 'Unable to load payment setup. Please try again.'
		});
	});

	it('returns the generic setup error for other 400 responses', async () => {
		createSetupIntentMock.mockRejectedValue(new ApiRequestError(400, 'customer not found'));

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			clientSecret: null,
			error: 'Unable to load payment setup. Please try again.'
		});
	});
});
