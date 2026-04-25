import type { PageLoad } from './$types';
import { marketingPricingPageData } from '../marketing_pricing';

export const load: PageLoad = () => {
	return marketingPricingPageData();
};
