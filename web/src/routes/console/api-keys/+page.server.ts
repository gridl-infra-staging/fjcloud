import type { PageServerLoad, Actions } from './$types';
import { createApiClient } from '$lib/server/api';
import {
	DASHBOARD_SESSION_EXPIRED_REDIRECT,
	customerFacingErrorMessage,
	isDashboardSessionExpiredError,
	mapDashboardSessionFailure
} from '$lib/server/auth-action-errors';
import { fail } from '@sveltejs/kit';
import { redirect } from '@sveltejs/kit';
import { EMPTY_SCOPE_REQUIRED_ERROR } from './api_keys_constants';

export const load: PageServerLoad = async ({ locals }) => {
	const api = createApiClient(locals.user?.token);
	try {
		const apiKeys = await api.getApiKeys();
		return { apiKeys };
	} catch (error) {
		if (isDashboardSessionExpiredError(error)) {
			redirect(303, DASHBOARD_SESSION_EXPIRED_REDIRECT);
		}
		return {
			apiKeys: [],
			loadError: customerFacingErrorMessage(error, 'Failed to load API keys')
		};
	}
};

export const actions: Actions = {
	create: async ({ request, locals }) => {
		const data = await request.formData();
		const name = (data.get('name') as string)?.trim();
		if (!name) return fail(400, { error: 'Name is required' });

		const scopes = data
			.getAll('scope')
			.filter((value): value is string => typeof value === 'string');
		if (scopes.length === 0) return fail(400, { error: EMPTY_SCOPE_REQUIRED_ERROR });

		const api = createApiClient(locals.user?.token);
		try {
			const result = await api.createApiKey({ name, scopes });
			return { createdKey: result.key };
		} catch (error) {
			const sessionFailure = mapDashboardSessionFailure(error);
			if (sessionFailure) return sessionFailure;
			return fail(400, { error: customerFacingErrorMessage(error, 'Failed to create API key') });
		}
	},
	revoke: async ({ request, locals }) => {
		const data = await request.formData();
		const keyId = data.get('keyId') as string;
		if (!keyId) return fail(400, { error: 'Missing key ID' });

		const api = createApiClient(locals.user?.token);
		try {
			await api.deleteApiKey(keyId);
			return { success: true };
		} catch (error) {
			const sessionFailure = mapDashboardSessionFailure(error);
			if (sessionFailure) return sessionFailure;
			return fail(400, { error: 'Failed to revoke API key' });
		}
	}
};
