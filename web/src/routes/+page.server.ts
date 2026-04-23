/**
 * @module Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/web/src/routes/+page.server.ts.
 */
import type { PageServerLoad } from './$types';
import { MARKETING_PRICING } from '$lib/pricing';

export const load: PageServerLoad = async () => {
	return { pricing: MARKETING_PRICING };
};
