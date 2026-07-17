import type { PageServerLoad, Actions } from './$types';
import { createAdminClient } from '$lib/admin-client';

export const load: PageServerLoad = async ({ fetch, platform }) => {
	const client = createAdminClient(undefined, platform?.env);
	client.setFetch(fetch);

	try {
		const coldIndexes = await client.getColdIndexes();
		return { coldIndexes };
	} catch {
		return { coldIndexes: [] };
	}
};

export const actions: Actions = {
	restore: async ({ request, fetch, platform }) => {
		const form = await request.formData();
		const snapshotId = form.get('snapshot_id') as string;
		if (!snapshotId) return { error: 'Missing snapshot_id' };

		const client = createAdminClient(undefined, platform?.env);
		client.setFetch(fetch);
		try {
			await client.restoreColdIndex(snapshotId);
			return { message: 'Restore initiated' };
		} catch (e) {
			return { error: e instanceof Error ? e.message : 'Restore failed' };
		}
	}
};
