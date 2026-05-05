import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ApiRequestError } from '$lib/api/client';

const getPaymentMethodsMock = vi.fn();
const createSetupIntentMock = vi.fn();
const setDefaultPaymentMethodMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		getPaymentMethods: getPaymentMethodsMock,
		createSetupIntent: createSetupIntentMock,
		setDefaultPaymentMethod: setDefaultPaymentMethodMock
	}))
}));

import { actions, load, prerender as billingPrerender } from './+page.server';

describe('billing route prerender contract', () => {
	it('opts out of prerender because it defines form actions', () => {
		expect(billingPrerender).toBe(false);
	});
});

describe('Billing page server load', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('returns payment methods and setup intent data when billing APIs are available', async () => {
		getPaymentMethodsMock.mockResolvedValue([
			{
				id: 'pm_default',
				card_brand: 'visa',
				last4: '4242',
				exp_month: 12,
				exp_year: 2030,
				is_default: true
			}
		]);
		createSetupIntentMock.mockResolvedValue({ client_secret: 'seti_secret_123' });

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			billingUnavailable: false,
			paymentMethods: [
				{
					id: 'pm_default',
					card_brand: 'visa',
					last4: '4242',
					exp_month: 12,
					exp_year: 2030,
					is_default: true
				}
			],
			setupIntentClientSecret: 'seti_secret_123',
			setupIntentError: null
		});
		expect(createSetupIntentMock).toHaveBeenCalledTimes(1);
	});

	it('returns billingUnavailable for service_not_configured from payment methods', async () => {
		getPaymentMethodsMock.mockRejectedValue(new ApiRequestError(503, 'service_not_configured'));

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			billingUnavailable: true,
			paymentMethods: [],
			setupIntentClientSecret: null,
			setupIntentError: null
		});
		expect(createSetupIntentMock).not.toHaveBeenCalled();
	});

	it('keeps billing page available when payment methods returns no stripe customer linked', async () => {
		getPaymentMethodsMock.mockRejectedValue(new ApiRequestError(400, 'no stripe customer linked'));

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			billingUnavailable: false,
			paymentMethods: [],
			setupIntentClientSecret: null,
			setupIntentError: null
		});
		expect(createSetupIntentMock).not.toHaveBeenCalled();
	});

	it('redirects to login when payment methods load hits an expired session', async () => {
		getPaymentMethodsMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		await expect(load({ locals: { user: { token: 'jwt-token' } } } as never)).rejects.toMatchObject(
			{
				status: 303,
				location: '/login?reason=session_expired'
			}
		);
	});

	it('returns billingUnavailable when setup-intent reports service_not_configured', async () => {
		getPaymentMethodsMock.mockResolvedValue([]);
		createSetupIntentMock.mockRejectedValue(new ApiRequestError(503, 'service_not_configured'));

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			billingUnavailable: true,
			paymentMethods: [],
			setupIntentClientSecret: null,
			setupIntentError: null
		});
	});

	it('returns billingUnavailable when setup-intent reports no stripe customer linked', async () => {
		getPaymentMethodsMock.mockResolvedValue([]);
		createSetupIntentMock.mockRejectedValue(new ApiRequestError(400, 'no stripe customer linked'));

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			billingUnavailable: true,
			paymentMethods: [],
			setupIntentClientSecret: null,
			setupIntentError: null
		});
	});

	it('redirects to login when setup-intent load hits an expired session', async () => {
		getPaymentMethodsMock.mockResolvedValue([]);
		createSetupIntentMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		await expect(load({ locals: { user: { token: 'jwt-token' } } } as never)).rejects.toMatchObject(
			{
				status: 303,
				location: '/login?reason=session_expired'
			}
		);
	});

	it('returns setup error when setup-intent fails for unrelated reasons', async () => {
		getPaymentMethodsMock.mockResolvedValue([]);
		createSetupIntentMock.mockRejectedValue(new ApiRequestError(500, 'internal server error'));

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			billingUnavailable: false,
			paymentMethods: [],
			setupIntentClientSecret: null,
			setupIntentError: 'Unable to load payment setup. Please try again.'
		});
	});

	it('rethrows non-contract payment method failures', async () => {
		getPaymentMethodsMock.mockRejectedValue(new ApiRequestError(500, 'internal server error'));

		await expect(load({ locals: { user: { token: 'jwt-token' } } } as never)).rejects.toThrow(
			'internal server error'
		);
	});
});

describe('Billing page server actions', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('setDefaultPaymentMethod action calls billing API and returns updated payment method id', async () => {
		setDefaultPaymentMethodMock.mockResolvedValue(undefined);
		const formData = new FormData();
		formData.set('paymentMethodId', 'pm_nondefault_123');

		const result = await actions.setDefaultPaymentMethod({
			locals: { user: { token: 'jwt-token' } },
			request: new Request('http://localhost/dashboard/billing?/setDefaultPaymentMethod', {
				method: 'POST',
				body: formData
			})
		} as never);

		expect(setDefaultPaymentMethodMock).toHaveBeenCalledWith('pm_nondefault_123');
		expect(result).toEqual({ updatedDefaultPaymentMethodId: 'pm_nondefault_123' });
	});

	it('setDefaultPaymentMethod action rejects missing payment method id', async () => {
		const formData = new FormData();
		formData.set('paymentMethodId', '   ');

		const result = await actions.setDefaultPaymentMethod({
			locals: { user: { token: 'jwt-token' } },
			request: new Request('http://localhost/dashboard/billing?/setDefaultPaymentMethod', {
				method: 'POST',
				body: formData
			})
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					error: 'Unable to update default payment method. Please try again.'
				})
			})
		);
		expect(setDefaultPaymentMethodMock).not.toHaveBeenCalled();
	});
});
