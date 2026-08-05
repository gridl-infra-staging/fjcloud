import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { expect } from 'vitest';
import { screen, within } from '@testing-library/svelte';
import type {
	AdminFleetDeployment,
	AdminReplicaEntry,
	VmDetail,
	VmHostMetricsResponse,
	VmInventoryItem,
	VmLifecycleEvent
} from '$lib/admin-client';
import { parseRealPipelineOracle } from '../../../../tests/fixtures/real_pipeline_oracle';

export function makeDeployment(
	overrides: Partial<AdminFleetDeployment> = {}
): AdminFleetDeployment {
	return {
		id: 'aaaaaaaa-1111-2222-3333-444444444444',
		customer_id: 'cccccccc-1111-2222-3333-444444444444',
		region: 'us-east-1',
		vm_provider: 'aws',
		status: 'running',
		health_status: 'healthy',
		flapjack_url: 'https://node1.flapjack.foo',
		created_at: '2026-02-10T12:00:00Z',
		last_health_check_at: '2026-02-21T10:00:00Z',
		...overrides
	};
}

export const FLEET_FIXTURES: AdminFleetDeployment[] = [
	makeDeployment({
		id: 'aaaaaaaa-0001-0000-0000-000000000001',
		region: 'us-east-1',
		vm_provider: 'aws',
		status: 'running',
		health_status: 'healthy'
	}),
	makeDeployment({
		id: 'aaaaaaaa-0002-0000-0000-000000000002',
		region: 'eu-central-1',
		vm_provider: 'hetzner',
		status: 'running',
		health_status: 'unhealthy',
		flapjack_url: 'https://node2.flapjack.foo',
		last_health_check_at: '2026-02-21T09:30:00Z'
	}),
	makeDeployment({
		id: 'aaaaaaaa-0003-0000-0000-000000000003',
		region: 'us-east-1',
		vm_provider: 'aws',
		status: 'provisioning',
		health_status: 'unknown',
		flapjack_url: null,
		last_health_check_at: null
	}),
	makeDeployment({
		id: 'aaaaaaaa-0004-0000-0000-000000000004',
		region: 'eu-north-1',
		vm_provider: 'hetzner',
		status: 'stopped',
		health_status: 'unknown',
		flapjack_url: 'https://node4.flapjack.foo'
	}),
	makeDeployment({
		id: 'aaaaaaaa-0005-0000-0000-000000000005',
		region: 'us-east-1',
		vm_provider: 'aws',
		status: 'failed',
		health_status: 'unhealthy',
		flapjack_url: null
	})
];

export const VM_FIXTURES: VmInventoryItem[] = [
	{
		id: 'vm-aaaaaaaa-0001-0000-0000-000000000001',
		provider: 'aws',
		hostname: 'vm-abc.flapjack.foo',
		region: 'us-east-1',
		status: 'running',
		flapjack_url: 'http://127.0.0.1:9001',
		capacity: { disk_bytes: 200, cpu_cores: 4, indexing_rps: 100 },
		current_load: { disk_bytes: 50, cpu_cores: 1, query_rps: 20 },
		tenant_count: 2,
		index_count: 3,
		health: 'healthy',
		created_at: '2026-02-10T12:00:00Z',
		updated_at: '2026-02-21T10:00:00Z'
	},
	{
		id: 'vm-aaaaaaaa-0002-0000-0000-000000000002',
		provider: 'aws',
		hostname: 'vm-def.flapjack.foo',
		region: 'us-east-1',
		status: 'active',
		flapjack_url: 'http://127.0.0.1:9002',
		capacity: { disk_bytes: 300, mem_rss_bytes: 800 },
		current_load: { disk_bytes: 150, mem_rss_bytes: 200 },
		tenant_count: 4,
		index_count: 6,
		health: 'unhealthy',
		created_at: '2026-02-11T12:00:00Z',
		updated_at: '2026-02-21T10:05:00Z'
	},
	{
		id: 'vm-bbbbbbbb-0003-0000-0000-000000000003',
		provider: 'hetzner',
		hostname: 'vm-ghi.flapjack.foo',
		region: 'eu-central-1',
		status: 'maintenance',
		flapjack_url: 'https://vm-ghi.flapjack.foo',
		capacity: { disk_bytes: 0, cpu_cores: 8 },
		current_load: { disk_bytes: 80, cpu_cores: 2 },
		tenant_count: 0,
		index_count: 0,
		health: 'unknown',
		created_at: '2026-02-12T12:00:00Z',
		updated_at: '2026-02-21T10:10:00Z'
	}
];

export const REPLICA_FIXTURES: AdminReplicaEntry[] = [
	{
		id: 'rep-aaaaaaaa-0001-0000-0000-000000000001',
		customer_id: 'cccccccc-1111-2222-3333-444444444444',
		tenant_id: 'tenant-1',
		replica_region: 'eu-west-1',
		status: 'active',
		lag_ops: 0,
		primary_vm_id: 'vm-aaaaaaaa-0001-0000-0000-000000000001',
		primary_vm_hostname: 'vm-abc.flapjack.foo',
		primary_vm_region: 'us-east-1',
		replica_vm_id: 'vm-aaaaaaaa-0002-0000-0000-000000000002',
		replica_vm_hostname: 'vm-def.flapjack.foo',
		created_at: '2026-02-10T12:00:00Z',
		updated_at: '2026-02-21T10:00:00Z'
	}
];

export const VM_ID = 'aaaaaaaa-0001-0000-0000-000000000001';
export const REPLACEMENT_VM_ID = 'dddddddd-0001-0000-0000-000000000001';
export const FALLBACK_REPLACEMENT_VM_ID = 'dddddddd-0002-0000-0000-000000000002';
export const ORACLE_RENDER_TIMEOUT_MS = 60_000;

export const REAL_PIPELINE_ORACLE = parseRealPipelineOracle(
	JSON.parse(
		readFileSync(
			join(
				process.cwd(),
				'..',
				'docs/runbooks/evidence/local-real-pipeline-oracle/2026_07_26_stage_03/oracle_redacted.json'
			),
			'utf8'
		)
	)
);

export const ORACLE_SELECTED_VM = REAL_PIPELINE_ORACLE.topology.vms.find(
	(vm) => vm.id === REAL_PIPELINE_ORACLE.topology.selected_vm_id
)!;

export const ORACLE_VM_DETAIL_FIXTURE: VmDetail = {
	vm: {
		id: ORACLE_SELECTED_VM.id,
		region: ORACLE_SELECTED_VM.region,
		provider: ORACLE_SELECTED_VM.provider,
		provider_vm_id: null,
		hostname: ORACLE_SELECTED_VM.hostname,
		flapjack_url: ORACLE_SELECTED_VM.flapjack_url,
		capacity: ORACLE_SELECTED_VM.capacity,
		current_load: ORACLE_SELECTED_VM.current_load,
		status: ORACLE_SELECTED_VM.status,
		created_at: ORACLE_SELECTED_VM.created_at,
		updated_at: ORACLE_SELECTED_VM.updated_at
	},
	tenants: Array.from({ length: ORACLE_SELECTED_VM.index_count }, (_, index) => ({
		customer_id: `oracle-customer-${index}`,
		tenant_id: `oracle-index-${index}`,
		deployment_id: `oracle-deployment-${index}`,
		vm_id: ORACLE_SELECTED_VM.id,
		tier: 'active',
		resource_quota: {},
		created_at: ORACLE_SELECTED_VM.created_at
	}))
};

export const VM_DETAIL_FIXTURE: VmDetail = {
	vm: {
		id: VM_ID,
		region: 'us-east-1',
		provider: 'aws',
		provider_vm_id: 'i-0abc123def456',
		hostname: 'vm-abc.flapjack.foo',
		flapjack_url: 'https://vm-abc.flapjack.foo',
		capacity: { cpu_cores: 4, ram_mb: 8192, disk_gb: 100 },
		current_load: { cpu_cores: 2.5, ram_mb: 4096, disk_gb: 45 },
		status: 'active',
		created_at: '2026-02-10T12:00:00Z',
		updated_at: '2026-02-22T10:00:00Z'
	},
	tenants: [
		{
			customer_id: 'bbbbbbbb-0001-0000-0000-000000000001',
			tenant_id: 'products',
			deployment_id: 'cccccccc-0001-0000-0000-000000000001',
			vm_id: VM_ID,
			tier: 'active',
			resource_quota: {},
			created_at: '2026-02-15T12:00:00Z'
		},
		{
			customer_id: 'bbbbbbbb-0002-0000-0000-000000000002',
			tenant_id: 'orders',
			deployment_id: 'cccccccc-0002-0000-0000-000000000002',
			vm_id: VM_ID,
			tier: 'active',
			resource_quota: { max_query_rps: 200 },
			created_at: '2026-02-16T12:00:00Z'
		}
	]
};

export const LIFECYCLE_EVENTS_FIXTURE = [
	{
		id: 'eeeeeeee-0002-0000-0000-000000000002',
		vm_id: VM_ID,
		event_type: 'replacement_completed',
		detail: { replacement_vm_id: REPLACEMENT_VM_ID },
		created_at: '2026-02-22T10:05:00Z'
	},
	{
		id: 'eeeeeeee-0001-0000-0000-000000000001',
		vm_id: VM_ID,
		event_type: 'detected_dead',
		detail: { dead_hostname: 'vm-abc.flapjack.foo' },
		created_at: '2026-02-22T10:00:00Z'
	}
] satisfies VmLifecycleEvent[];

export const EMPTY_LIFECYCLE_RESPONSE: [] = [];

export type FleetPageRenderData = {
	environment: string;
	isAuthenticated: boolean;
	fleet: AdminFleetDeployment[];
	fleetAvailable: boolean;
	vms: VmInventoryItem[];
	vmCapacityAvailable: boolean;
	hostMetricsByVmId: Record<string, VmHostMetricsResponse | null>;
	replicas: AdminReplicaEntry[];
	replicaPlacementAvailable: boolean;
};

export function fleetPageData(overrides: Partial<FleetPageRenderData> = {}): FleetPageRenderData {
	return {
		environment: 'test',
		isAuthenticated: true,
		fleet: [],
		fleetAvailable: true,
		vms: [],
		vmCapacityAvailable: true,
		hostMetricsByVmId: {},
		replicas: [],
		replicaPlacementAvailable: true,
		...overrides
	};
}

export function makeHostMetrics(
	overrides: Partial<VmHostMetricsResponse> = {}
): VmHostMetricsResponse {
	return {
		id: 'metrics-aaaaaaaa-0001-0000-0000-000000000001',
		vm_id: 'vm-aaaaaaaa-0001-0000-0000-000000000001',
		collected_at: '2026-02-21T10:00:00Z',
		cpu_pct: 12.5,
		mem_used_bytes: 3,
		mem_total_bytes: 4,
		disk_used_bytes: 25,
		disk_total_bytes: 100,
		net_rx_bytes: 1024,
		net_tx_bytes: 2048,
		created_at: '2026-02-21T10:00:01Z',
		...overrides
	};
}

// Collects the exact per-line text of a replica placement cell. The multi-role
// branch renders one <div> per fact; the single-line branches render bare text.
export function replicaCellLines(cell: HTMLElement): string[] {
	const divs = cell.querySelectorAll('div');
	if (divs.length > 0) {
		return Array.from(divs, (div) => (div.textContent ?? '').replace(/\s+/g, ' ').trim());
	}
	return [(cell.textContent ?? '').replace(/\s+/g, ' ').trim()];
}

export function cellText(cell: HTMLElement): string {
	return (cell.textContent ?? '').replace(/\s+/g, ' ').trim();
}

export function assertOracleCapacityRows(expectedVms: VmInventoryItem[]) {
	expect(screen.getAllByTestId(/^capacity-row-/)).toHaveLength(expectedVms.length);
	for (const vm of expectedVms) {
		const row = screen.getByTestId(`capacity-row-${vm.id}`);
		expect(within(row).getByRole('link', { name: vm.hostname })).toHaveAttribute(
			'href',
			`/admin/fleet/${vm.id}`
		);
		expect(row).toHaveTextContent(vm.region);
		expect(row).toHaveTextContent(vm.provider);
		expect(row).toHaveTextContent(vm.status);
		expect(cellText(screen.getByTestId(`vm-health-${vm.id}`))).toBe(vm.health);
		expect(cellText(screen.getByTestId(`tenant-count-${vm.id}`))).toBe(String(vm.tenant_count));
		expect(cellText(screen.getByTestId(`index-count-${vm.id}`))).toBe(String(vm.index_count));
		for (const key of ['cpu_weight', 'disk_bytes', 'indexing_rps', 'mem_rss_bytes', 'query_rps']) {
			expect(cellText(screen.getByTestId(`capacity-util-${vm.id}-${key}`))).toBe('0%');
		}
	}
}

type LifecycleEvents = VmLifecycleEvent[] | null;

export function vmDetailPageData(lifecycleEvents: LifecycleEvents = EMPTY_LIFECYCLE_RESPONSE) {
	return {
		environment: 'test',
		isAuthenticated: true,
		...VM_DETAIL_FIXTURE,
		lifecycleEvents,
		hostMetrics: null
	};
}

export function oraclePageData(
	hostMetrics: VmHostMetricsResponse | null = REAL_PIPELINE_ORACLE.host_metrics.samples[0]
) {
	return {
		environment: 'test',
		isAuthenticated: true,
		...ORACLE_VM_DETAIL_FIXTURE,
		lifecycleEvents: EMPTY_LIFECYCLE_RESPONSE,
		hostMetrics
	};
}

export function requestPath(input: string | URL | Request): string {
	const raw = input instanceof Request ? input.url : input.toString();
	return new URL(raw, 'http://localhost').pathname;
}

export function mockVmDetailAndLifecycleFetch(
	lifecycleResponse: unknown,
	lifecycleStatus = 200,
	hostMetricsResponse: unknown = null
): { fetch: (input: string | URL | Request) => Promise<Response>; requestedPaths: string[] } {
	const requestedPaths: string[] = [];
	return {
		requestedPaths,
		fetch: async (input: string | URL | Request) => {
			const path = requestPath(input);
			requestedPaths.push(path);
			if (path === `/admin/vms/${VM_ID}`) {
				return new Response(JSON.stringify(VM_DETAIL_FIXTURE), { status: 200 });
			}
			if (path === `/admin/vms/${VM_ID}/lifecycle-events`) {
				return new Response(JSON.stringify(lifecycleResponse), { status: lifecycleStatus });
			}
			if (path === `/admin/vms/${VM_ID}/host-metrics`) {
				return new Response(JSON.stringify(hostMetricsResponse), { status: 200 });
			}
			return new Response(JSON.stringify({ error: `unexpected path ${path}` }), { status: 500 });
		}
	};
}
