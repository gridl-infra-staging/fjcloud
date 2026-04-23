import { loadStripe, type Stripe } from '@stripe/stripe-js';

let stripePromise: Promise<Stripe | null> | null = null;

export function getStripe(): Promise<Stripe | null> {
	if (!stripePromise) {
		const key = import.meta.env.VITE_STRIPE_PUBLISHABLE_KEY;
		if (!key) {
			console.warn('VITE_STRIPE_PUBLISHABLE_KEY not set — Stripe will not load');
			return Promise.resolve(null);
		}
		stripePromise = loadStripe(key);
	}
	return stripePromise;
}
