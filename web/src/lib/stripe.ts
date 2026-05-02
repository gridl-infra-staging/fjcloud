import { loadStripe, type Stripe } from '@stripe/stripe-js';

let stripePromise: Promise<Stripe | null> | null = null;

interface PublishableKeyResponse {
	publishableKey?: unknown;
}

async function loadStripeAtRuntime(): Promise<Stripe | null> {
	try {
		const response = await fetch('/api/stripe/publishable-key');
		if (!response.ok) {
			return null;
		}

		const body = (await response.json()) as PublishableKeyResponse;
		if (typeof body.publishableKey !== 'string' || body.publishableKey.length === 0) {
			return null;
		}

		return await loadStripe(body.publishableKey);
	} catch {
		return null;
	}
}

export function getStripe(): Promise<Stripe | null> {
	if (!stripePromise) {
		stripePromise = loadStripeAtRuntime();
	}
	return stripePromise;
}
