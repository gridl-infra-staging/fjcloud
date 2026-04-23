import type { PageServerLoad, Actions } from './$types';
import { createApiClient } from '$lib/server/api';
import { fail } from '@sveltejs/kit';

export const load: PageServerLoad = async ({ locals }) => {
	const api = createApiClient(locals.user?.token);
	try {
		const apiKeys = await api.getApiKeys();
		return { apiKeys };
	} catch {
		return { apiKeys: [] };
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

		const api = createApiClient(locals.user?.token);
		try {
			const result = await api.createApiKey({ name, scopes });
			return { createdKey: result.key };
		} catch {
			return fail(400, { error: 'Failed to create API key' });
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
		} catch {
			return fail(400, { error: 'Failed to revoke API key' });
		}
	}
};
