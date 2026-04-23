import type { Actions, PageServerLoad } from './$types';
import { createAdminClient } from '$lib/admin-client';
import type { AdminFleetDeployment, VmInventoryItem } from '$lib/admin-client';
import { fail } from '@sveltejs/kit';

export const load: PageServerLoad = async ({ fetch, depends }) => {
	depends('admin:fleet');
	const client = createAdminClient();
	client.setFetch(fetch);

	// Fetch fleet and VMs independently so one failure doesn't hide the other.
	const [fleet, vms] = await Promise.all([
		client.getFleet().catch(() => [] as AdminFleetDeployment[]),
		client.listVms().catch(() => [] as VmInventoryItem[])
	]);

	return { fleet, vms };
};

// Server action for killing a local VM's Flapjack process.
// The Kill button POSTs here with the VM ID in FormData. This keeps the
// ADMIN_KEY on the server side — it's never exposed to the browser.
export const actions: Actions = {
	killVm: async ({ request, fetch }) => {
		const data = await request.formData();
		const vmId = data.get('vmId');
		if (!vmId || typeof vmId !== 'string') {
			return fail(400, { error: 'Missing vmId' });
		}

		const client = createAdminClient();
		client.setFetch(fetch);

		try {
			const result = await client.killVm(vmId);
			return { success: true, region: result.region, port: result.port };
		} catch (err) {
			const message = err instanceof Error ? err.message : 'Failed to kill VM';
			return fail(500, { error: message });
		}
	}
};
