import { requireNonEmptyString } from './contract-guards';

type StripeCustomerLookupResponse = {
	invoice_settings?: {
		default_payment_method?: string | null;
	} | null;
};

type ReadStripeDefaultPaymentMethodParams = {
	stripeCustomerId: string;
	stripeSecretKey: string;
	contextLabel: string;
	fetchImpl?: typeof fetch;
};

export async function readStripeDefaultPaymentMethod({
	stripeCustomerId,
	stripeSecretKey,
	contextLabel,
	fetchImpl = fetch
}: ReadStripeDefaultPaymentMethodParams): Promise<string> {
	const normalizedStripeCustomerId = requireNonEmptyString(
		stripeCustomerId,
		`${contextLabel} requires a non-empty stripeCustomerId`
	);
	const normalizedStripeSecretKey = requireNonEmptyString(
		stripeSecretKey,
		`${contextLabel} requires STRIPE_SECRET_KEY`
	);

	const response = await fetchImpl(
		`https://api.stripe.com/v1/customers/${encodeURIComponent(normalizedStripeCustomerId)}`,
		{
			method: 'GET',
			headers: {
				Authorization: `Bearer ${normalizedStripeSecretKey}`
			}
		}
	);
	if (!response.ok) {
		throw new Error(
			`${contextLabel} Stripe customer read failed: ${response.status} ${await response.text()}`
		);
	}

	const payload = (await response.json()) as StripeCustomerLookupResponse;
	return requireNonEmptyString(
		payload.invoice_settings?.default_payment_method ?? '',
		`${contextLabel} Stripe customer has no invoice_settings.default_payment_method`
	);
}
