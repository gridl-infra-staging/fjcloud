/**
 * @module Stub summary for web/src/routes/console/migrate/+page.server.ts.
 */
import type { PageServerLoad } from './$types';
import { createApiClient } from '$lib/server/api';
import { mapDashboardSessionFailure } from '$lib/server/auth-action-errors';

/**
 * TODO: Document load.
 */
export const load: PageServerLoad = async ({ locals }) => {
	const api = createApiClient(locals.user?.token);
	try {
		return {
			availability: await api.getAlgoliaMigrationAvailability()
		};
	} catch (err) {
		const sessionFailure = mapDashboardSessionFailure(err);
		if (sessionFailure) return sessionFailure;
		return {
			availability: {
				available: false,
				reason: 'temporarily_unavailable',
				message: 'Algolia migration is temporarily unavailable while we replace the importer.',
				capabilities: { cancel: false, resume: false, replace: false }
			}
		};
	}
};
