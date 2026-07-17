import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import { SUPPORT_EMAIL } from '$lib/format';

const getPaymentMethodsMock = vi.fn();
const createSetupIntentMock = vi.fn();
const setDefaultPaymentMethodMock = vi.fn();
const getUpgradeStatusMock = vi.fn();
const upgradeToSharedMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		getPaymentMethods: getPaymentMethodsMock,
		createSetupIntent: createSetupIntentMock,
		setDefaultPaymentMethod: setDefaultPaymentMethodMock,
		getUpgradeStatus: getUpgradeStatusMock,
		upgradeToShared: upgradeToSharedMock
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
		getUpgradeStatusMock.mockResolvedValue({
			stripe_customer_id: 'cus_123',
			has_default_payment_method: true,
			upgrade_ready: true
		});

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
			setupIntentError: null,
			upgradeStatus: {
				stripe_customer_id: 'cus_123',
				has_default_payment_method: true,
				upgrade_ready: true
			}
		});
		expect(createSetupIntentMock).toHaveBeenCalledTimes(1);
		expect(getUpgradeStatusMock).toHaveBeenCalledTimes(1);
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
			setupIntentError: null,
			upgradeStatus: null
		});
		expect(createSetupIntentMock).not.toHaveBeenCalled();
		expect(getUpgradeStatusMock).not.toHaveBeenCalled();
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
			setupIntentError: null,
			upgradeStatus: null
		});
		expect(createSetupIntentMock).not.toHaveBeenCalled();
		expect(getUpgradeStatusMock).not.toHaveBeenCalled();
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

	it('does not redirect to login for quota_exceeded 403 errors from payment-methods load', async () => {
		getPaymentMethodsMock.mockRejectedValue(new ApiRequestError(403, 'quota_exceeded'));

		await expect(load({ locals: { user: { token: 'jwt-token' } } } as never)).rejects.toMatchObject(
			{
				status: 403,
				message: 'quota_exceeded'
			}
		);
	});

	it('returns billingUnavailable when setup-intent reports service_not_configured', async () => {
		getPaymentMethodsMock.mockResolvedValue([]);
		createSetupIntentMock.mockRejectedValue(new ApiRequestError(503, 'service_not_configured'));
		getUpgradeStatusMock.mockResolvedValue({
			stripe_customer_id: null,
			has_default_payment_method: false,
			upgrade_ready: false
		});

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			billingUnavailable: true,
			paymentMethods: [],
			setupIntentClientSecret: null,
			setupIntentError: null,
			upgradeStatus: {
				stripe_customer_id: null,
				has_default_payment_method: false,
				upgrade_ready: false
			}
		});
	});

	it('returns billingUnavailable when setup-intent reports no stripe customer linked', async () => {
		getPaymentMethodsMock.mockResolvedValue([]);
		createSetupIntentMock.mockRejectedValue(new ApiRequestError(400, 'no stripe customer linked'));
		getUpgradeStatusMock.mockResolvedValue({
			stripe_customer_id: null,
			has_default_payment_method: false,
			upgrade_ready: false
		});

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			billingUnavailable: true,
			paymentMethods: [],
			setupIntentClientSecret: null,
			setupIntentError: null,
			upgradeStatus: {
				stripe_customer_id: null,
				has_default_payment_method: false,
				upgrade_ready: false
			}
		});
	});

	it('redirects to login when setup-intent load hits an expired session', async () => {
		getPaymentMethodsMock.mockResolvedValue([]);
		createSetupIntentMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));
		getUpgradeStatusMock.mockResolvedValue({
			stripe_customer_id: 'cus_123',
			has_default_payment_method: true,
			upgrade_ready: true
		});

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
		getUpgradeStatusMock.mockResolvedValue({
			stripe_customer_id: 'cus_123',
			has_default_payment_method: true,
			upgrade_ready: true
		});

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			billingUnavailable: false,
			paymentMethods: [],
			setupIntentClientSecret: null,
			setupIntentError: 'Unable to load payment setup. Please try again.',
			upgradeStatus: {
				stripe_customer_id: 'cus_123',
				has_default_payment_method: true,
				upgrade_ready: true
			}
		});
	});

	it('rethrows non-contract payment method failures', async () => {
		getPaymentMethodsMock.mockRejectedValue(new ApiRequestError(500, 'internal server error'));

		await expect(load({ locals: { user: { token: 'jwt-token' } } } as never)).rejects.toThrow(
			'internal server error'
		);
	});

	it('returns billingUnavailable when upgrade-status reports service_not_configured', async () => {
		getPaymentMethodsMock.mockResolvedValue([]);
		createSetupIntentMock.mockResolvedValue({ client_secret: 'seti_secret_123' });
		getUpgradeStatusMock.mockRejectedValue(new ApiRequestError(503, 'service_not_configured'));

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			billingUnavailable: true,
			paymentMethods: [],
			setupIntentClientSecret: null,
			setupIntentError: null,
			upgradeStatus: null
		});
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
			request: new Request('http://localhost/console/billing?/setDefaultPaymentMethod', {
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
			request: new Request('http://localhost/console/billing?/setDefaultPaymentMethod', {
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

	it('upgradeToShared action returns success outcome for successful upgrade', async () => {
		upgradeToSharedMock.mockResolvedValue({
			billing_plan: 'shared',
			subscription_cycle_anchor_at: '2026-05-17T12:00:00Z',
			stripe_invoice_id: 'in_test_123',
			activation_amount_cents: 500
		});

		const result = await actions.upgradeToShared({
			locals: { user: { token: 'jwt-token' } },
			request: new Request('http://localhost/console/billing?/upgradeToShared', {
				method: 'POST',
				body: new FormData()
			})
		} as never);

		expect(upgradeToSharedMock).toHaveBeenCalledTimes(1);
		expect(result).toEqual({
			upgradeOutcome: {
				status: 'success',
				activationAmountCents: 500
			}
		});
	});

	it('upgradeToShared action maps 402 requires-action response to requires_action outcome', async () => {
		upgradeToSharedMock.mockRejectedValue(
			new ApiRequestError(402, 'payment_required', {
				body: {
					error: 'payment_required',
					code: 'invoice_payment_intent_requires_action',
					message: 'Authentication required.'
				}
			})
		);

		const result = await actions.upgradeToShared({
			locals: { user: { token: 'jwt-token' } },
			request: new Request('http://localhost/console/billing?/upgradeToShared', {
				method: 'POST',
				body: new FormData()
			})
		} as never);

		expect(result).toEqual({
			upgradeOutcome: {
				status: 'requires_action'
			}
		});
	});

	it('upgradeToShared action maps 402 card decline to declined outcome', async () => {
		upgradeToSharedMock.mockRejectedValue(
			new ApiRequestError(402, 'payment_required', {
				body: {
					error: 'payment_required',
					code: 'card_declined',
					message: 'Your card was declined.'
				}
			})
		);

		const result = await actions.upgradeToShared({
			locals: { user: { token: 'jwt-token' } },
			request: new Request('http://localhost/console/billing?/upgradeToShared', {
				method: 'POST',
				body: new FormData()
			})
		} as never);

		expect(result).toEqual({
			upgradeOutcome: {
				status: 'declined',
				message: 'Your card was declined.'
			}
		});
	});

	it('upgradeToShared action maps missing default payment method to needs_card outcome', async () => {
		upgradeToSharedMock.mockRejectedValue(
			new ApiRequestError(400, 'default payment method required')
		);

		const result = await actions.upgradeToShared({
			locals: { user: { token: 'jwt-token' } },
			request: new Request('http://localhost/console/billing?/upgradeToShared', {
				method: 'POST',
				body: new FormData()
			})
		} as never);

		expect(result).toEqual({
			upgradeOutcome: {
				status: 'missing_payment_method'
			}
		});
	});

	it('upgradeToShared action maps billing service_not_configured to an error outcome', async () => {
		upgradeToSharedMock.mockRejectedValue(new ApiRequestError(503, 'service_not_configured'));

		const result = await actions.upgradeToShared({
			locals: { user: { token: 'jwt-token' } },
			request: new Request('http://localhost/console/billing?/upgradeToShared', {
				method: 'POST',
				body: new FormData()
			})
		} as never);

		expect(result).toEqual({
			upgradeOutcome: {
				status: 'error',
				message: `Billing is being set up for your account. Please contact ${SUPPORT_EMAIL} if this persists.`
			}
		});
	});

	it('upgradeToShared action maps stale-tab 409 to already_shared outcome', async () => {
		upgradeToSharedMock.mockRejectedValue(
			new ApiRequestError(409, 'customer is not eligible for free-to-shared upgrade')
		);

		const result = await actions.upgradeToShared({
			locals: { user: { token: 'jwt-token' } },
			request: new Request('http://localhost/console/billing?/upgradeToShared', {
				method: 'POST',
				body: new FormData()
			})
		} as never);

		expect(result).toEqual({
			upgradeOutcome: {
				status: 'already_shared'
			}
		});
	});
});
