import { MARKETING_PRICING } from '$lib/pricing';

export interface MarketingPricingPageData {
	pricing: typeof MARKETING_PRICING;
}

export function marketingPricingPageData(): MarketingPricingPageData {
	return { pricing: MARKETING_PRICING };
}
