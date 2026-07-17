import { fail } from '@sveltejs/kit';
import type { PageServerLoad, Actions } from './$types';
import { ApiRequestError } from '$lib/api/client';
import { createApiClient } from '$lib/server/api';
import { mapDashboardSessionFailure } from '$lib/server/auth-action-errors';
import { retryTransientDashboardApiRequest } from '$lib/server/transient-api-retry';

export const load: PageServerLoad = async ({ parent }) => {
	await parent();
	return {};
};

async function handleCreateIndex(request: Request, locals: App.Locals) {
	const formData = await request.formData();
	const name = formData.get('name') as string;
	const region = formData.get('region') as string;

	if (!name || !region) {
		return fail(400, { error: 'Index name and region are required' });
	}

	const api = createApiClient(locals.user?.token);
	try {
		const result = await retryTransientDashboardApiRequest(() => api.createIndex(name, region));
		return { created: true, index: result, indexName: name, region };
	} catch (e) {
		const sessionFailure = mapDashboardSessionFailure(e);
		if (sessionFailure) return sessionFailure;
		return toActionFailure(e, 'Failed to create index');
	}
}

function toActionFailure(error: unknown, fallbackMessage: string) {
	if (error instanceof ApiRequestError) {
		if (error.status >= 500) {
			return fail(error.status, { error: fallbackMessage });
		}
		return fail(error.status, { error: error.message });
	}

	return fail(500, { error: fallbackMessage });
}

export const actions: Actions = {
	createIndex: async ({ request, locals }) => handleCreateIndex(request, locals),
	retryIndex: async ({ request, locals }) => handleCreateIndex(request, locals),

	getCredentials: async ({ locals }) => {
		const api = createApiClient(locals.user?.token);
		try {
			const creds = await retryTransientDashboardApiRequest(() => api.generateCredentials());
			return { credentials: creds };
		} catch (e) {
			const sessionFailure = mapDashboardSessionFailure(e);
			if (sessionFailure) return sessionFailure;
			return toActionFailure(e, 'Failed to generate credentials');
		}
	}
};
