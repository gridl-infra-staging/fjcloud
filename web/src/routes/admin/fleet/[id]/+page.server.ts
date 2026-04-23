import { error } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';
import { createAdminClient } from '$lib/admin-client';

export const load: PageServerLoad = async ({ fetch, params, depends }) => {
	depends(`admin:fleet:detail:${params.id}`);

	const client = createAdminClient();
	client.setFetch(fetch);

	const detail = await client.getVmDetail(params.id).catch(() => error(404, 'VM not found'));

	return {
		vm: detail.vm,
		tenants: detail.tenants
	};
};
