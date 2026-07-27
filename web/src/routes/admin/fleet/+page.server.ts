import type { Actions, PageServerLoad } from './$types';
import { createAdminClient } from '$lib/admin-client';
import type {
	AdminClient,
	AdminFleetDeployment,
	AdminReplicaEntry,
	VmHostMetricsResponse,
	VmInventoryItem
} from '$lib/admin-client';
import { fail } from '@sveltejs/kit';

const VM_ID_PATTERN = /^[A-Za-z0-9-]+$/;

function isLocalVmUrl(url: string): boolean {
	try {
		const parsed = new URL(url);
		return (
			parsed.hostname === '127.0.0.1' ||
			parsed.hostname === 'localhost' ||
			parsed.hostname === '::1'
		);
	} catch {
		return false;
	}
}

async function loadHostMetricsByVmId(
	client: AdminClient,
	vms: VmInventoryItem[]
): Promise<Record<string, VmHostMetricsResponse | null>> {
	const entries = await Promise.all(
		vms.map(async (vm) => {
			const metrics = await client.getVmHostMetrics(vm.id).catch(() => null);
			return [vm.id, metrics?.vm_id === vm.id ? metrics : null];
		})
	);
	return Object.fromEntries(entries);
}

export const load: PageServerLoad = async ({ fetch, depends, platform }) => {
	depends('admin:fleet');
	const client = createAdminClient(undefined, platform?.env);
	client.setFetch(fetch);

	// Fetch fleet, VMs, and replica placement independently so one failure
	// doesn't hide the others. Availability flags distinguish failed requests
	// from real empty result sets so the UI never presents false empty facts.
	const [fleetResult, vmResult, replicaResult] = await Promise.all([
		client
			.getFleet()
			.then((fleet) => ({ fleet, available: true }))
			.catch(() => ({ fleet: [] as AdminFleetDeployment[], available: false })),
		client
			.listVms()
			.then((vms) => ({ vms, available: true }))
			.catch(() => ({ vms: [] as VmInventoryItem[], available: false })),
		client
			.getReplicas()
			.then((replicas) => ({ replicas, available: true }))
			.catch(() => ({ replicas: [] as AdminReplicaEntry[], available: false }))
	]);
	const hostMetricsByVmId = vmResult.available
		? await loadHostMetricsByVmId(client, vmResult.vms)
		: {};

	return {
		fleet: fleetResult.fleet,
		fleetAvailable: fleetResult.available,
		vms: vmResult.vms,
		vmCapacityAvailable: vmResult.available,
		hostMetricsByVmId,
		replicas: replicaResult.replicas,
		replicaPlacementAvailable: replicaResult.available
	};
};

// Server action for killing a local VM's Flapjack process.
// The Kill button POSTs here with the VM ID in FormData. This keeps the
// ADMIN_KEY on the server side — it's never exposed to the browser.
export const actions: Actions = {
	killVm: async ({ request, fetch, platform }) => {
		const data = await request.formData();
		const vmId = data.get('vmId');
		if (!vmId || typeof vmId !== 'string') {
			return fail(400, { error: 'Missing vmId' });
		}
		if (!VM_ID_PATTERN.test(vmId)) {
			return fail(400, { error: 'Invalid vmId' });
		}

		const client = createAdminClient(undefined, platform?.env);
		client.setFetch(fetch);
		const vms = await client.listVms().catch(() => null);
		if (!vms) {
			return fail(503, { error: 'VM inventory unavailable' });
		}
		const vm = vms.find((candidate) => candidate.id === vmId);
		if (!vm || !isLocalVmUrl(vm.flapjack_url)) {
			return fail(403, { error: 'VM is not eligible for local kill' });
		}

		try {
			const result = await client.killVm(vmId);
			return { success: true, region: result.region, port: result.port };
		} catch (err) {
			const message = err instanceof Error ? err.message : 'Failed to kill VM';
			return fail(500, { error: message });
		}
	}
};
