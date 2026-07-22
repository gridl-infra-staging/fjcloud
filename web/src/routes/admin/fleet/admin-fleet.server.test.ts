import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { VmHostMetricsResponse } from '$lib/admin-client';
import { FLEET_FIXTURES, REPLICA_FIXTURES, VM_FIXTURES } from './admin_fleet_fixtures';

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

const HOST_METRICS_FIXTURE: VmHostMetricsResponse = {
	id: 'metrics-aaaaaaaa-0001-0000-0000-000000000001',
	vm_id: 'vm-aaaaaaaa-0001-0000-0000-000000000001',
	collected_at: '2026-07-20T12:05:00Z',
	cpu_pct: 62.25,
	mem_used_bytes: 5_368_709_120,
	mem_total_bytes: 8_589_934_592,
	disk_used_bytes: 53_687_091_200,
	disk_total_bytes: 107_374_182_400,
	net_rx_bytes: 223_456_789,
	net_tx_bytes: 198_765_432,
	created_at: '2026-07-20T12:05:03Z'
};

function requestPath(input: string | URL | Request): string {
	return typeof input === 'string' ? input : input.toString();
}

function countRequests(paths: string[], suffix: string): number {
	return paths.filter((path) => path.endsWith(suffix)).length;
}

beforeEach(() => {
	process.env.ADMIN_KEY = 'test-admin-key';
});

afterEach(() => {
	delete process.env.ADMIN_KEY;
});

describe('Fleet page server load', () => {
	it('loads fleet and VM data via admin client', async () => {
		const { load } = await import('./+page.server');

		const capturedPaths: string[] = [];
		const mockFetch = async (input: string | URL | Request) => {
			const path = requestPath(input);
			capturedPaths.push(path);
			if (path.includes('/admin/fleet')) {
				return new Response(JSON.stringify(FLEET_FIXTURES), { status: 200 });
			}
			if (path.includes('/admin/replicas')) {
				return new Response(JSON.stringify(REPLICA_FIXTURES), { status: 200 });
			}
			if (path.endsWith('/admin/vms')) {
				return new Response(JSON.stringify(VM_FIXTURES), { status: 200 });
			}
			if (path.includes('/admin/vms/') && path.endsWith('/host-metrics')) {
				return new Response(JSON.stringify(null), { status: 200 });
			}
			return new Response(JSON.stringify([]), { status: 200 });
		};

		const result = await load({
			fetch: mockFetch,
			depends: () => {}
		} as never);

		expect(capturedPaths.some((p) => p.includes('/admin/fleet'))).toBe(true);
		expect(capturedPaths.some((p) => p.endsWith('/admin/vms'))).toBe(true);
		expect(capturedPaths.some((p) => p.includes('/admin/replicas'))).toBe(true);
		expect(result!.fleetAvailable).toBe(true);
		expect(result!.fleet).toHaveLength(5);
		expect(result!.fleet[0].status).toBe('running');
		expect(result!.vms).toEqual(VM_FIXTURES);
		expect(result!.replicas).toEqual(REPLICA_FIXTURES);
		expect(result!.replicaPlacementAvailable).toBe(true);
	});

	it('composes host metrics for every listed VM without changing base availability', async () => {
		const { load } = await import('./+page.server');
		const capturedPaths: string[] = [];

		const mockFetch = async (input: string | URL | Request) => {
			const path = requestPath(input);
			capturedPaths.push(path);
			if (path.endsWith(`${VM_FIXTURES[0].id}/host-metrics`)) {
				return new Response(JSON.stringify(HOST_METRICS_FIXTURE), { status: 200 });
			}
			if (path.endsWith(`${VM_FIXTURES[1].id}/host-metrics`)) {
				return new Response(JSON.stringify(null), { status: 200 });
			}
			if (path.endsWith(`${VM_FIXTURES[2].id}/host-metrics`)) {
				return new Response('Internal Server Error', { status: 500 });
			}
			if (path.includes('/admin/fleet')) {
				return new Response(JSON.stringify(FLEET_FIXTURES), { status: 200 });
			}
			if (path.includes('/admin/replicas')) {
				return new Response(JSON.stringify(REPLICA_FIXTURES), { status: 200 });
			}
			if (path.endsWith('/admin/vms')) {
				return new Response(JSON.stringify(VM_FIXTURES), { status: 200 });
			}
			return new Response(JSON.stringify([]), { status: 200 });
		};

		const result = await load({
			fetch: mockFetch,
			depends: () => {}
		} as never);

		expect(result!.hostMetricsByVmId).toEqual({
			[VM_FIXTURES[0].id]: HOST_METRICS_FIXTURE,
			[VM_FIXTURES[1].id]: null,
			[VM_FIXTURES[2].id]: null
		});
		for (const vm of VM_FIXTURES) {
			expect(countRequests(capturedPaths, `/admin/vms/${vm.id}/host-metrics`)).toBe(1);
		}
		expect(result!.fleet).toEqual(FLEET_FIXTURES);
		expect(result!.fleetAvailable).toBe(true);
		expect(result!.vms).toEqual(VM_FIXTURES);
		expect(result!.replicas).toEqual(REPLICA_FIXTURES);
		expect(result!.vmCapacityAvailable).toBe(true);
		expect(result!.replicaPlacementAvailable).toBe(true);
	});

	it('keeps VM and replica data while marking fleet unavailable on a fleet-only failure', async () => {
		const { load } = await import('./+page.server');

		const mockFetch = async (input: string | URL | Request) => {
			const path = requestPath(input);
			if (path.includes('/admin/fleet')) {
				return new Response('Internal Server Error', { status: 500 });
			}
			if (path.endsWith('/admin/vms')) {
				return new Response(JSON.stringify(VM_FIXTURES), { status: 200 });
			}
			if (path.includes('/admin/replicas')) {
				return new Response(JSON.stringify(REPLICA_FIXTURES), { status: 200 });
			}
			if (path.includes('/admin/vms/') && path.endsWith('/host-metrics')) {
				return new Response(JSON.stringify(null), { status: 200 });
			}
			return new Response(JSON.stringify([]), { status: 200 });
		};

		const result = await load({
			fetch: mockFetch,
			depends: () => {}
		} as never);

		expect(result!.fleet).toEqual([]);
		expect(result!.fleetAvailable).toBe(false);
		expect(result!.vms).toEqual(VM_FIXTURES);
		expect(result!.vmCapacityAvailable).toBe(true);
		expect(result!.replicas).toEqual(REPLICA_FIXTURES);
		expect(result!.replicaPlacementAvailable).toBe(true);
		expect(result!.hostMetricsByVmId).toEqual({
			[VM_FIXTURES[0].id]: null,
			[VM_FIXTURES[1].id]: null,
			[VM_FIXTURES[2].id]: null
		});
	});

	it('keeps fleet and VM rows when only the replicas endpoint fails', async () => {
		const { load } = await import('./+page.server');

		const mockFetch = async (input: string | URL | Request) => {
			const path = requestPath(input);
			if (path.includes('/admin/replicas')) {
				return new Response('Internal Server Error', { status: 500 });
			}
			if (path.includes('/admin/fleet')) {
				return new Response(JSON.stringify(FLEET_FIXTURES), { status: 200 });
			}
			if (path.endsWith('/admin/vms')) {
				return new Response(JSON.stringify(VM_FIXTURES), { status: 200 });
			}
			if (path.includes('/admin/vms/') && path.endsWith('/host-metrics')) {
				return new Response(JSON.stringify(null), { status: 200 });
			}
			return new Response(JSON.stringify([]), { status: 200 });
		};

		const result = await load({
			fetch: mockFetch,
			depends: () => {}
		} as never);

		expect(result!.fleet).toHaveLength(5);
		expect(result!.fleetAvailable).toBe(true);
		expect(result!.vms).toEqual(VM_FIXTURES);
		expect(result!.replicas).toEqual([]);
		expect(result!.replicaPlacementAvailable).toBe(false);
	});

	it('keeps fleet and replica data while marking VM capacity unavailable on a VM-only failure', async () => {
		const { load } = await import('./+page.server');
		const capturedPaths: string[] = [];

		const mockFetch = async (input: string | URL | Request) => {
			const path = requestPath(input);
			capturedPaths.push(path);
			if (path.endsWith('/admin/vms')) {
				return new Response('Internal Server Error', { status: 500 });
			}
			if (path.includes('/admin/fleet')) {
				return new Response(JSON.stringify(FLEET_FIXTURES), { status: 200 });
			}
			if (path.includes('/admin/replicas')) {
				return new Response(JSON.stringify(REPLICA_FIXTURES), { status: 200 });
			}
			return new Response(JSON.stringify([]), { status: 200 });
		};

		const result = await load({
			fetch: mockFetch,
			depends: () => {}
		} as never);

		expect(result!.fleet).toEqual(FLEET_FIXTURES);
		expect(result!.fleetAvailable).toBe(true);
		expect(result!.vms).toEqual([]);
		expect(result!.vmCapacityAvailable).toBe(false);
		expect(result!.replicas).toEqual(REPLICA_FIXTURES);
		expect(result!.replicaPlacementAvailable).toBe(true);
		expect(result!.hostMetricsByVmId).toEqual({});
		expect(capturedPaths.some((path) => path.includes('/host-metrics'))).toBe(false);
	});

	it('returns empty arrays on API error', async () => {
		const { load } = await import('./+page.server');

		const mockFetch = async () => {
			return new Response('Internal Server Error', { status: 500 });
		};

		const result = await load({
			fetch: mockFetch,
			depends: () => {}
		} as never);

		expect(result!.fleet).toEqual([]);
		expect(result!.fleetAvailable).toBe(false);
		expect(result!.vms).toEqual([]);
		expect(result!.vmCapacityAvailable).toBe(false);
		expect(result!.replicas).toEqual([]);
		expect(result!.hostMetricsByVmId).toEqual({});
		expect(result!.replicaPlacementAvailable).toBe(false);
	});
});

describe('Fleet page server actions', () => {
	it('rejects vm ids with path-control characters before calling the admin API', async () => {
		const { actions } = await import('./+page.server');
		const fetchSpy = vi.fn(async () => new Response(JSON.stringify({}), { status: 200 }));
		const form = new FormData();
		form.set('vmId', '../customers/target?force=1');

		const result = await actions.killVm({
			request: new Request('http://example.test/admin/fleet', {
				method: 'POST',
				body: form
			}),
			fetch: fetchSpy
		} as never);

		if (!result || !('status' in result) || !('data' in result)) {
			throw new Error('killVm should return a validation failure');
		}
		expect(result.status).toBe(400);
		expect(result.data).toEqual({ error: 'Invalid vmId' });
		expect(fetchSpy).not.toHaveBeenCalled();
	});
});
