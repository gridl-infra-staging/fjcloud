/**
 * @module Page server load handler for the dashboard indexes route that fetches user indexes and available regions with session expiration detection and fallback defaults.
 */
import { fail, redirect } from '@sveltejs/kit';
import type { PageServerLoad, Actions } from './$types';
import { ApiRequestError } from '$lib/api/client';
import type { Index } from '$lib/api/types';
import { createApiClient } from '$lib/server/api';
import { DEFAULT_INTERNAL_REGIONS } from '$lib/format';
import {
	DASHBOARD_SESSION_EXPIRED_REDIRECT,
	customerFacingErrorMessage,
	isDashboardSessionExpiredError,
	mapDashboardSessionFailure
} from '$lib/server/auth-action-errors';
import { retryTransientDashboardApiRequest } from '$lib/server/transient-api-retry';

/**
 * Fetches user indexes and available regions from the API, with automatic fallback to empty indexes and default regions on failure. Redirects to login if the session has expired.
 */
export const load: PageServerLoad = async ({ locals }) => {
	const api = createApiClient(locals.user?.token);
	let indexes: Index[] = [];
	try {
		indexes = await retryTransientDashboardApiRequest(() => api.getIndexes());
	} catch (error) {
		if (isDashboardSessionExpiredError(error)) {
			redirect(303, DASHBOARD_SESSION_EXPIRED_REDIRECT);
		}
	}

	const regions = await api.getInternalRegions().catch(() => DEFAULT_INTERNAL_REGIONS);
	return { indexes, regions };
};

export const actions: Actions = {
	create: async ({ request, locals }) => {
		const data = await request.formData();
		const name = (data.get('name') as string)?.trim();
		const region = (data.get('region') as string)?.trim();

		if (!name) return fail(400, { error: 'Index name is required' });
		if (!region) return fail(400, { error: 'Region is required' });

		const api = createApiClient(locals.user?.token);
		try {
			await retryTransientDashboardApiRequest(() => api.createIndex(name, region));
			return { created: true };
		} catch (e) {
			const sessionFailure = mapDashboardSessionFailure(e);
			if (sessionFailure) return sessionFailure;
			if (e instanceof ApiRequestError && e.status === 409) {
				return fail(400, { error: 'Index already exists' });
			}
			const message = customerFacingErrorMessage(e, 'Failed to create index');
			return fail(400, { error: message });
		}
	},
	delete: async ({ request, locals }) => {
		const data = await request.formData();
		const name = data.get('name') as string;
		if (!name) return fail(400, { error: 'Missing index name' });

		const api = createApiClient(locals.user?.token);
		try {
			await api.deleteIndex(name);
			return { deleted: true };
		} catch (e) {
			const sessionFailure = mapDashboardSessionFailure(e);
			if (sessionFailure) return sessionFailure;
			const message = customerFacingErrorMessage(e, 'Failed to delete index');
			return fail(400, { error: message });
		}
	}
};
