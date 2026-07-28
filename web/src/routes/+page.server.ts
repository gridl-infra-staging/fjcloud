import type { PageServerLoad } from './$types';
import { marketingPricingPageData } from './marketing_pricing';

// Force dynamic SSR ownership for `/`: with root-layout prerender enabled and
// crawl disabled, omitting this lets SvelteKit drop `/` from the server manifest.
export const prerender = false;

export const load: PageServerLoad = async () => {
	return marketingPricingPageData();
};
