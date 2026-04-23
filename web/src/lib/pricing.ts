/** Shared marketing pricing constants used by the landing page pricing table. */

export interface RegionPricing {
	id: string;
	display_name: string;
	multiplier: string;
}

export interface MarketingPricing {
	storage_rate_per_mb_month: string;
	cold_storage_rate_per_gb_month: string;
	free_tier_mb: number;
	region_pricing: RegionPricing[];
	minimum_spend_cents: number;
	cta_label: string;
	free_tier_promise: string;
}

const NO_CARD_TAGLINE = 'No credit card required';
const FREE_TIER_PROMISE = `Create your free account. ${NO_CARD_TAGLINE}.`;

export const MARKETING_PRICING: MarketingPricing = {
	storage_rate_per_mb_month: '$0.05',
	cold_storage_rate_per_gb_month: '$0.02',
	free_tier_mb: 250,
	region_pricing: [
		{ id: 'us-east-1', display_name: 'US East (Virginia)', multiplier: '1.00x' },
		{ id: 'eu-west-1', display_name: 'EU West (Ireland)', multiplier: '1.00x' },
		{ id: 'eu-central-1', display_name: 'EU Central (Germany)', multiplier: '0.70x' },
		{ id: 'eu-north-1', display_name: 'EU North (Helsinki)', multiplier: '0.75x' },
		{ id: 'us-east-2', display_name: 'US East (Ashburn)', multiplier: '0.80x' },
		{ id: 'us-west-1', display_name: 'US West (Oregon)', multiplier: '0.80x' }
	],
	minimum_spend_cents: 1000,
	cta_label: 'Get Started Free',
	free_tier_promise: FREE_TIER_PROMISE
};
