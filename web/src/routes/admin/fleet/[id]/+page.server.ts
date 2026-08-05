import { error } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';
import { AdminClientError, type AdminClient } from '$lib/admin-client';
import type { VmHostMetricsResponse } from '$lib/admin-client';
import {
	redirectIfAdminSessionAuthError,
	requireDurableAdminSession
} from '$lib/server/admin-session';

async function loadHostMetrics(client: AdminClient, vmId: string) {
	const metrics: VmHostMetricsResponse | null = await client
		.getVmHostMetrics(vmId)
		.catch((error) => {
			redirectIfAdminSessionAuthError(error);
			return null;
		});
	return metrics?.vm_id === vmId ? metrics : null;
}

export const load: PageServerLoad = async (event) => {
	const { params } = event;
	event.depends(`admin:fleet:detail:${params.id}`);

	const { adminClient: client } = await requireDurableAdminSession(event);

	const detail = await client.getVmDetail(params.id).catch((requestError) => {
		redirectIfAdminSessionAuthError(requestError);
		if (requestError instanceof AdminClientError && requestError.status === 404) {
			error(404, 'VM not found');
		}
		throw requestError;
	});
	const [lifecycleEvents, hostMetrics] = await Promise.all([
		client.getVmLifecycleEvents(params.id).catch((error) => {
			redirectIfAdminSessionAuthError(error);
			return null;
		}),
		loadHostMetrics(client, params.id)
	]);

	return {
		vm: detail.vm,
		tenants: detail.tenants,
		lifecycleEvents,
		hostMetrics
	};
};
