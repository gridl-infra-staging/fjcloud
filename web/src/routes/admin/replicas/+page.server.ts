import type { PageServerLoad } from './$types';
import type { AdminReplicaEntry } from '$lib/admin-client';
import {
	redirectIfAdminSessionAuthError,
	requireDurableAdminSession
} from '$lib/server/admin-session';

export const load: PageServerLoad = async (event) => {
	event.depends('admin:replicas');
	const { adminClient: client } = await requireDurableAdminSession(event);

	try {
		const replicas = await client.getReplicas();
		return { replicas };
	} catch (error) {
		redirectIfAdminSessionAuthError(error);
		return { replicas: [] as AdminReplicaEntry[] };
	}
};
