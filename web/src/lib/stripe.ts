import { loadStripe, type Stripe } from '@stripe/stripe-js';

let stripePromise: Promise<Stripe | null> | null = null;
let stripeBootstrapFailed = false;

interface PublishableKeyResponse {
	publishableKey?: unknown;
}

async function loadStripeAtRuntime(): Promise<Stripe | null> {
	try {
		const response = await fetch('/api/stripe/publishable-key');
		if (!response.ok) {
			stripeBootstrapFailed = true;
			return null;
		}

		const body = (await response.json()) as PublishableKeyResponse;
		if (typeof body.publishableKey !== 'string' || body.publishableKey.length === 0) {
			stripeBootstrapFailed = true;
			return null;
		}

		const loadedStripe = await loadStripe(body.publishableKey);
		stripeBootstrapFailed = !loadedStripe;
		return loadedStripe;
	} catch {
		stripeBootstrapFailed = true;
		return null;
	}
}

export function getStripe(): Promise<Stripe | null> {
	if (!stripePromise) {
		stripePromise = loadStripeAtRuntime();
	}
	return stripePromise;
}

export function resetStripeBootstrapForRetry(): void {
	if (!stripeBootstrapFailed) return;
	stripePromise = null;
	stripeBootstrapFailed = false;
}
