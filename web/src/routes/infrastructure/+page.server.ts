/**
 * @module Stub summary for web/src/routes/infrastructure/+page.server.ts.
 */
import { createCanonicalPublicApiClient } from '$lib/server/api';
import type { PageServerLoad } from './$types';
import {
	parsePublicInfrastructureResponse,
	type InfrastructureRouteData
} from './infrastructure_contract';

const PUBLIC_INFRASTRUCTURE_ERROR_MESSAGE = 'Infrastructure data is temporarily unavailable.';

/**
 * TODO: Document load.
 */
export const load: PageServerLoad = async ({ fetch }): Promise<InfrastructureRouteData> => {
	try {
		const infrastructure = parsePublicInfrastructureResponse(
			await createCanonicalPublicApiClient(fetch).getPublicInfrastructure()
		);
		if (infrastructure === null) {
			throw new Error('public infrastructure response did not match the route contract');
		}
		return { status: 'success', infrastructure };
	} catch {
		return {
			status: 'error',
			message: PUBLIC_INFRASTRUCTURE_ERROR_MESSAGE
		};
	}
};
