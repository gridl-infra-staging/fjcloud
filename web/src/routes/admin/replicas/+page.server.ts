import type { PageServerLoad } from './$types';
import { createAdminClient } from '$lib/admin-client';
import type { AdminReplicaEntry } from '$lib/admin-client';

export const load: PageServerLoad = async ({ fetch, depends, platform }) => {
	depends('admin:replicas');
	const client = createAdminClient(undefined, platform?.env);
	client.setFetch(fetch);

	try {
		const replicas = await client.getReplicas();
		return { replicas };
	} catch {
		return { replicas: [] as AdminReplicaEntry[] };
	}
};
