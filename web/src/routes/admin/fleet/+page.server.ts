import type { Actions, PageServerLoad } from './$types';
import type {
	AdminClient,
	AdminFleetDeployment,
	AdminReplicaEntry,
	VmHostMetricsResponse,
	VmInventoryItem
} from '$lib/admin-client';
import { fail } from '@sveltejs/kit';
import {
	redirectIfAdminSessionAuthError,
	requireDurableAdminSession
} from '$lib/server/admin-session';

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
			const metrics = await client.getVmHostMetrics(vm.id).catch((error) => {
				redirectIfAdminSessionAuthError(error);
				return null;
			});
			return [vm.id, metrics?.vm_id === vm.id ? metrics : null];
		})
	);
	return Object.fromEntries(entries);
}

export const load: PageServerLoad = async (event) => {
	event.depends('admin:fleet');
	const { adminClient: client } = await requireDurableAdminSession(event);

	// Fetch fleet, VMs, and replica placement independently so one failure
	// doesn't hide the others. Availability flags distinguish failed requests
	// from real empty result sets so the UI never presents false empty facts.
	const [fleetResult, vmResult, replicaResult] = await Promise.all([
		client
			.getFleet()
			.then((fleet) => ({ fleet, available: true }))
			.catch((error) => {
				redirectIfAdminSessionAuthError(error);
				return { fleet: [] as AdminFleetDeployment[], available: false };
			}),
		client
			.listVms()
			.then((vms) => ({ vms, available: true }))
			.catch((error) => {
				redirectIfAdminSessionAuthError(error);
				return { vms: [] as VmInventoryItem[], available: false };
			}),
		client
			.getReplicas()
			.then((replicas) => ({ replicas, available: true }))
			.catch((error) => {
				redirectIfAdminSessionAuthError(error);
				return { replicas: [] as AdminReplicaEntry[], available: false };
			})
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
// The Kill button POSTs here with the VM ID in FormData. The operator's
// durable session stays on the server — it's never exposed to the browser.
export const actions: Actions = {
	killVm: async (event) => {
		const { adminClient: client } = await requireDurableAdminSession(event);

		const data = await event.request.formData();
		const vmId = data.get('vmId');
		if (!vmId || typeof vmId !== 'string') {
			return fail(400, { error: 'Missing vmId' });
		}
		if (!VM_ID_PATTERN.test(vmId)) {
			return fail(400, { error: 'Invalid vmId' });
		}

		const vms = await client.listVms().catch((error) => {
			redirectIfAdminSessionAuthError(error);
			return null;
		});
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
			redirectIfAdminSessionAuthError(err);
			const message = err instanceof Error ? err.message : 'Failed to kill VM';
			return fail(500, { error: message });
		}
	}
};
