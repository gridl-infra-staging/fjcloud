import { afterEach, describe, expect, it, vi } from 'vitest';
import { readStripeDefaultPaymentMethod } from '../../tests/fixtures/staging_stripe_lookup';

function makeJsonResponse(status: number, body: unknown): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'Content-Type': 'application/json' }
	});
}

describe('staging Stripe lookup helper (LB-3)', () => {
	afterEach(() => {
		vi.restoreAllMocks();
	});

	it('reads default payment method from Stripe customer invoice_settings', async () => {
		const fetchMock = vi.fn().mockResolvedValue(
			makeJsonResponse(200, {
				invoice_settings: {
					default_payment_method: 'pm_default_123'
				}
			})
		);

		await expect(
			readStripeDefaultPaymentMethod({
				stripeCustomerId: 'cus_123',
				stripeSecretKey: 'sk_test_123',
				contextLabel: 'staging-stripe-lookup-test',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).resolves.toBe('pm_default_123');
		expect(fetchMock).toHaveBeenCalledWith('https://api.stripe.com/v1/customers/cus_123', {
			method: 'GET',
			headers: {
				Authorization: 'Bearer sk_test_123'
			}
		});
	});

	it('fails closed when Stripe customer has no default payment method', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValue(
				makeJsonResponse(200, { invoice_settings: { default_payment_method: null } })
			);

		await expect(
			readStripeDefaultPaymentMethod({
				stripeCustomerId: 'cus_123',
				stripeSecretKey: 'sk_test_123',
				contextLabel: 'staging-stripe-lookup-test',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow('Stripe customer has no invoice_settings.default_payment_method');
	});

	it('fails closed when Stripe customer read is non-2xx', async () => {
		const fetchMock = vi.fn().mockResolvedValue(
			new Response('permission denied', {
				status: 403
			})
		);

		await expect(
			readStripeDefaultPaymentMethod({
				stripeCustomerId: 'cus_123',
				stripeSecretKey: 'sk_test_123',
				contextLabel: 'staging-stripe-lookup-test',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow('Stripe customer read failed: 403 permission denied');
	});
});
