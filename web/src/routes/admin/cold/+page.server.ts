import type { PageServerLoad, Actions } from './$types';
import {
	redirectIfAdminSessionAuthError,
	requireDurableAdminSession
} from '$lib/server/admin-session';

export const load: PageServerLoad = async (event) => {
	const { adminClient: client } = await requireDurableAdminSession(event);

	try {
		const coldIndexes = await client.getColdIndexes();
		return { coldIndexes };
	} catch (error) {
		redirectIfAdminSessionAuthError(error);
		return { coldIndexes: [] };
	}
};

export const actions: Actions = {
	restore: async (event) => {
		const { adminClient: client } = await requireDurableAdminSession(event);

		const form = await event.request.formData();
		const snapshotId = form.get('snapshot_id') as string;
		if (!snapshotId) return { error: 'Missing snapshot_id' };
		try {
			await client.restoreColdIndex(snapshotId);
			return { message: 'Restore initiated' };
		} catch (e) {
			redirectIfAdminSessionAuthError(e);
			return { error: e instanceof Error ? e.message : 'Restore failed' };
		}
	}
};
