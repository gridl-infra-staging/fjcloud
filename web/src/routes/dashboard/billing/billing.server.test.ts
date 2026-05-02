import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ApiRequestError } from '$lib/api/client';

const getPaymentMethodsMock = vi.fn();
const createBillingPortalSessionMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		getPaymentMethods: getPaymentMethodsMock,
		createBillingPortalSession: createBillingPortalSessionMock
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

	it('returns billingUnavailable false when payment methods API is available', async () => {
		getPaymentMethodsMock.mockResolvedValue([]);

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			billingUnavailable: false
		});
	});

	it('returns billingUnavailable when API responds with service_not_configured', async () => {
		getPaymentMethodsMock.mockRejectedValue(new ApiRequestError(503, 'service_not_configured'));

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			billingUnavailable: true
		});
	});

	it('keeps billing action available when API responds with no stripe customer linked', async () => {
		getPaymentMethodsMock.mockRejectedValue(new ApiRequestError(400, 'no stripe customer linked'));

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			billingUnavailable: false
		});
	});

	it('rethrows no stripe customer linked when status is not 400', async () => {
		getPaymentMethodsMock.mockRejectedValue(new ApiRequestError(503, 'no stripe customer linked'));

		await expect(load({ locals: { user: { token: 'jwt-token' } } } as never)).rejects.toThrow(
			'no stripe customer linked'
		);
	});

	it('redirects to login when billing availability load hits an expired session', async () => {
		getPaymentMethodsMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		await expect(load({ locals: { user: { token: 'jwt-token' } } } as never)).rejects.toMatchObject(
			{
				status: 303,
				location: '/login?reason=session_expired'
			}
		);
	});

	it('rethrows non-service_not_configured errors', async () => {
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

	it('posts server-owned return_url to billing portal endpoint and redirects with 303', async () => {
		createBillingPortalSessionMock.mockResolvedValue({
			portal_url: 'https://billing.stripe.com/session/test_123'
		});

		const actionCall = actions.manageBilling({
			locals: { user: { token: 'jwt-token' } },
			url: new URL('https://console.example.com/dashboard/billing'),
			request: new Request('https://console.example.com/dashboard/billing?/manageBilling', {
				method: 'POST'
			})
		} as never);

		await expect(actionCall).rejects.toMatchObject({
			status: 303,
			location: 'https://billing.stripe.com/session/test_123'
		});
		expect(createBillingPortalSessionMock).toHaveBeenCalledWith({
			return_url: 'https://console.example.com/dashboard/billing'
		});
	});

	it('rejects non-https portal URL payloads from upstream', async () => {
		createBillingPortalSessionMock.mockResolvedValue({
			portal_url: 'http://billing.stripe.com/session/test_123'
		});

		const result = await actions.manageBilling({
			locals: { user: { token: 'jwt-token' } },
			url: new URL('https://console.example.com/dashboard/billing'),
			request: new Request('https://console.example.com/dashboard/billing?/manageBilling', {
				method: 'POST'
			})
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: { error: 'Failed to open billing portal' }
			})
		);
	});

	it('rejects non-Stripe portal host payloads from upstream', async () => {
		createBillingPortalSessionMock.mockResolvedValue({
			portal_url: 'https://attacker.example/session/test_123'
		});

		const result = await actions.manageBilling({
			locals: { user: { token: 'jwt-token' } },
			url: new URL('https://console.example.com/dashboard/billing'),
			request: new Request('https://console.example.com/dashboard/billing?/manageBilling', {
				method: 'POST'
			})
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: { error: 'Failed to open billing portal' }
			})
		);
	});

	it('returns shared session-expired payload when portal creation hits 401', async () => {
		createBillingPortalSessionMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const result = await actions.manageBilling({
			locals: { user: { token: 'jwt-token' } },
			url: new URL('https://console.example.com/dashboard/billing'),
			request: new Request('https://console.example.com/dashboard/billing?/manageBilling', {
				method: 'POST'
			})
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 401,
				data: expect.objectContaining({
					_authSessionExpired: true,
					error: 'Unauthorized'
				})
			})
		);
	});

	it('returns shared session-expired payload when portal creation hits 403', async () => {
		createBillingPortalSessionMock.mockRejectedValue(new ApiRequestError(403, 'Forbidden'));

		const result = await actions.manageBilling({
			locals: { user: { token: 'jwt-token' } },
			url: new URL('https://console.example.com/dashboard/billing'),
			request: new Request('https://console.example.com/dashboard/billing?/manageBilling', {
				method: 'POST'
			})
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 403,
				data: expect.objectContaining({
					_authSessionExpired: true,
					error: 'Forbidden'
				})
			})
		);
	});

	it('returns failure payload when portal session creation fails', async () => {
		createBillingPortalSessionMock.mockRejectedValue(new Error('upstream unavailable'));

		const result = await actions.manageBilling({
			locals: { user: { token: 'jwt-token' } },
			url: new URL('https://console.example.com/dashboard/billing'),
			request: new Request('https://console.example.com/dashboard/billing?/manageBilling', {
				method: 'POST'
			})
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: { error: 'Failed to open billing portal' }
			})
		);
	});

	it('returns setup guidance when billing portal creation reports no stripe customer', async () => {
		createBillingPortalSessionMock.mockRejectedValue(
			new ApiRequestError(400, 'no stripe customer linked')
		);

		const result = await actions.manageBilling({
			locals: { user: { token: 'jwt-token' } },
			url: new URL('https://console.example.com/dashboard/billing'),
			request: new Request('https://console.example.com/dashboard/billing?/manageBilling', {
				method: 'POST'
			})
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: {
					error:
						'Billing is being set up for your account. Please contact support@flapjack.foo if this persists.'
				}
			})
		);
	});
});
