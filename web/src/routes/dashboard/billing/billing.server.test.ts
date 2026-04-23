import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ApiRequestError } from '$lib/api/client';

const getPaymentMethodsMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		getPaymentMethods: getPaymentMethodsMock
	}))
}));

import { load } from './+page.server';

describe('Billing page server load', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('returns billingUnavailable when API responds with service_not_configured', async () => {
		getPaymentMethodsMock.mockRejectedValue(
			new ApiRequestError(503, 'service_not_configured')
		);

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			paymentMethods: [],
			billingUnavailable: true
		});
	});

	it('returns billingUnavailable when API responds with no stripe customer linked', async () => {
		getPaymentMethodsMock.mockRejectedValue(
			new ApiRequestError(400, 'no stripe customer linked')
		);

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			paymentMethods: [],
			billingUnavailable: true
		});
	});

	it('rethrows no stripe customer linked when status is not 400', async () => {
		getPaymentMethodsMock.mockRejectedValue(
			new ApiRequestError(503, 'no stripe customer linked')
		);

		await expect(
			load({ locals: { user: { token: 'jwt-token' } } } as never)
		).rejects.toThrow('no stripe customer linked');
	});

	it('rethrows non-service_not_configured errors', async () => {
		getPaymentMethodsMock.mockRejectedValue(
			new ApiRequestError(500, 'internal server error')
		);

		await expect(
			load({ locals: { user: { token: 'jwt-token' } } } as never)
		).rejects.toThrow('internal server error');
	});
});
