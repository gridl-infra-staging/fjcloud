import { error } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';
import { AdminClientError, createAdminClient } from '$lib/admin-client';
import type { VmHostMetricsResponse } from '$lib/admin-client';

async function loadHostMetrics(client: ReturnType<typeof createAdminClient>, vmId: string) {
	const metrics: VmHostMetricsResponse | null = await client
		.getVmHostMetrics(vmId)
		.catch(() => null);
	return metrics?.vm_id === vmId ? metrics : null;
}

export const load: PageServerLoad = async ({ fetch, params, depends, platform }) => {
	depends(`admin:fleet:detail:${params.id}`);

	const client = createAdminClient(undefined, platform?.env);
	client.setFetch(fetch);

	const detail = await client.getVmDetail(params.id).catch((requestError) => {
		if (requestError instanceof AdminClientError && requestError.status === 404) {
			error(404, 'VM not found');
		}
		throw requestError;
	});
	const [lifecycleEvents, hostMetrics] = await Promise.all([
		client.getVmLifecycleEvents(params.id).catch(() => null),
		loadHostMetrics(client, params.id)
	]);

	return {
		vm: detail.vm,
		tenants: detail.tenants,
		lifecycleEvents,
		hostMetrics
	};
};
