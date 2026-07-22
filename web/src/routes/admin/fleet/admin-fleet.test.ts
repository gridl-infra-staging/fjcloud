import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import {
	FLEET_FIXTURES,
	REPLICA_FIXTURES,
	VM_FIXTURES,
	makeDeployment
} from './admin_fleet_fixtures';

// Mock SvelteKit modules before importing components
vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	invalidate: () => Promise.resolve()
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/admin/fleet') }
}));

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

import type {
	AdminFleetDeployment,
	AdminReplicaEntry,
	HealthCheckResponse,
	VmHostMetricsResponse,
	VmInventoryItem
} from '$lib/admin-client';

type FleetPageRenderData = {
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

function pageData(overrides: Partial<FleetPageRenderData> = {}): FleetPageRenderData {
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

function makeHostMetrics(overrides: Partial<VmHostMetricsResponse> = {}): VmHostMetricsResponse {
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
// branch renders one <div> per fact; the single-line branches ("No replicas",
// "Replica placement unavailable") render bare text with no child divs.
// Normalizing to an array of trimmed lines lets tests assert the complete cell
// output with exact equality, so an incorrect count (`Primary: 10`), extra role
// text, or a suffixed region label fails instead of passing a substring match.
function replicaCellLines(cell: HTMLElement): string[] {
	const divs = cell.querySelectorAll('div');
	if (divs.length > 0) {
		return Array.from(divs, (div) => (div.textContent ?? '').replace(/\s+/g, ' ').trim());
	}
	return [(cell.textContent ?? '').replace(/\s+/g, ' ').trim()];
}

function cellText(cell: HTMLElement): string {
	return (cell.textContent ?? '').replace(/\s+/g, ' ').trim();
}

beforeEach(() => {
	process.env.ADMIN_KEY = 'test-admin-key';
});

afterEach(() => {
	cleanup();
	delete process.env.ADMIN_KEY;
});

describe('Fleet dashboard', () => {
	it('renders summary cards with correct counts', async () => {
		const FleetPage = (await import('./+page.svelte')).default;

		render(FleetPage, {
			data: pageData({ fleet: FLEET_FIXTURES }),
			form: null
		});

		// This summary counts deployment rows, not canonical VM inventory rows.
		expect(screen.getByText('Total Deployments')).toBeInTheDocument();
		expect(screen.getByTestId('total-deployments')).toHaveTextContent('5');
		// By status
		expect(screen.getByTestId('running-count')).toHaveTextContent('2');
		expect(screen.getByTestId('provisioning-count')).toHaveTextContent('1');
		expect(screen.getByTestId('stopped-count')).toHaveTextContent('1');
		expect(screen.getByTestId('failed-count')).toHaveTextContent('1');
		// Unhealthy count
		expect(screen.getByTestId('unhealthy-count')).toHaveTextContent('2');
	});

	it('renders VM table with all deployment rows including provider column', async () => {
		const FleetPage = (await import('./+page.svelte')).default;

		render(FleetPage, {
			data: pageData({ fleet: FLEET_FIXTURES }),
			form: null
		});

		// Table headers — must include Provider
		// Use exact anchors (^/$) to avoid /ID/i matching "Provider"
		expect(screen.getByRole('columnheader', { name: /^ID$/i })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: /^Region$/i })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: /^Provider$/i })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: /^Status$/i })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: /^Health$/i })).toBeInTheDocument();

		// All 5 deployment rows rendered (plus header row)
		const rows = screen.getAllByRole('row');
		// header + 5 data rows
		expect(rows.length).toBe(6);
		expect(screen.getByTestId('fleet-row-aaaaaaaa-0001-0000-0000-000000000001')).toHaveTextContent(
			'running'
		);

		// Verify deployment regions appear in the table
		expect(screen.getAllByText('us-east-1')).toHaveLength(3);
		expect(screen.getAllByText('eu-central-1')).toHaveLength(1);
		expect(screen.getAllByText('eu-north-1')).toHaveLength(1);

		// Verify provider labels appear in the table
		expect(screen.getAllByText('aws')).toHaveLength(3);
		expect(screen.getAllByText('hetzner')).toHaveLength(2);
	});

	it('renders empty state when fleet is empty', async () => {
		const FleetPage = (await import('./+page.svelte')).default;

		render(FleetPage, {
			data: pageData(),
			form: null
		});

		expect(screen.getByTestId('total-deployments')).toHaveTextContent('0');
		expect(screen.getByText(/no deployments/i)).toBeInTheDocument();
	});

	it('distinguishes unavailable VM capacity from genuinely empty inventory', async () => {
		const FleetPage = (await import('./+page.svelte')).default;

		render(FleetPage, {
			data: pageData({ fleet: FLEET_FIXTURES, vmCapacityAvailable: false }),
			form: null
		});

		expect(screen.getByTestId('vm-capacity-unavailable')).toHaveTextContent(
			'VM capacity unavailable'
		);
		expect(screen.queryByTestId('capacity-table-body')).not.toBeInTheDocument();
	});

	it('distinguishes unavailable deployment data from a genuine empty fleet state', async () => {
		const FleetPage = (await import('./+page.svelte')).default;

		render(FleetPage, {
			data: pageData({
				fleetAvailable: false,
				vms: VM_FIXTURES,
				hostMetricsByVmId: Object.fromEntries(VM_FIXTURES.map((vm) => [vm.id, null]))
			}),
			form: null
		});

		expect(screen.getByTestId('fleet-unavailable')).toHaveTextContent(
			'Deployment data unavailable'
		);
		expect(screen.queryByText(/no deployments found/i)).not.toBeInTheDocument();
		expect(screen.queryByTestId('total-deployments')).not.toBeInTheDocument();
		expect(screen.queryByTestId('fleet-table-body')).not.toBeInTheDocument();
		expect(screen.getByTestId('capacity-table-body')).toBeInTheDocument();
	});

	it('links VM infrastructure hostnames to the VM detail route', async () => {
		const FleetPage = (await import('./+page.svelte')).default;

		render(FleetPage, {
			data: pageData({ vms: VM_FIXTURES }),
			form: null
		});

		const hostnameLink = screen.getByRole('link', { name: 'vm-abc.flapjack.foo' });
		expect(hostnameLink).toHaveAttribute(
			'href',
			'/admin/fleet/vm-aaaaaaaa-0001-0000-0000-000000000001'
		);
	});

	it('renders the VM capacity table with exact capacity, health, and count fields', async () => {
		const FleetPage = (await import('./+page.svelte')).default;

		render(FleetPage, {
			data: pageData({ vms: VM_FIXTURES }),
			form: null
		});

		const tableBody = screen.getByTestId('capacity-table-body');
		const firstRow = screen.getByTestId('capacity-row-vm-aaaaaaaa-0001-0000-0000-000000000001');
		const secondRow = screen.getByTestId('capacity-row-vm-aaaaaaaa-0002-0000-0000-000000000002');
		const thirdRow = screen.getByTestId('capacity-row-vm-bbbbbbbb-0003-0000-0000-000000000003');

		expect(within(tableBody).getAllByRole('row')).toHaveLength(3);
		expect(within(firstRow).getByRole('link', { name: 'vm-abc.flapjack.foo' })).toHaveAttribute(
			'href',
			'/admin/fleet/vm-aaaaaaaa-0001-0000-0000-000000000001'
		);
		expect(firstRow).toHaveTextContent('us-east-1');
		expect(firstRow).toHaveTextContent('aws');
		expect(firstRow).toHaveTextContent('running');
		expect(
			screen.getByTestId('vm-health-vm-aaaaaaaa-0001-0000-0000-000000000001')
		).toHaveTextContent('healthy');
		expect(
			screen.getByTestId('tenant-count-vm-aaaaaaaa-0001-0000-0000-000000000001')
		).toHaveTextContent('2');
		expect(
			screen.getByTestId('index-count-vm-aaaaaaaa-0001-0000-0000-000000000001')
		).toHaveTextContent('3');
		expect(
			screen.getByTestId('capacity-util-vm-aaaaaaaa-0001-0000-0000-000000000001-disk_bytes')
		).toHaveTextContent('25%');
		expect(
			screen.getByTestId('capacity-util-vm-aaaaaaaa-0001-0000-0000-000000000001-cpu_cores')
		).toHaveTextContent('25%');
		expect(
			screen.getByTestId('capacity-util-vm-aaaaaaaa-0001-0000-0000-000000000001-mem_rss_bytes')
		).toHaveTextContent('Unavailable');
		expect(screen.queryByRole('columnheader', { name: 'query_rps' })).not.toBeInTheDocument();
		expect(screen.queryByRole('columnheader', { name: 'indexing_rps' })).not.toBeInTheDocument();
		expect(
			screen.getByRole('columnheader', { name: /^disk_bytes \(proxy\)$/i })
		).toBeInTheDocument();
		expect(
			screen.getByRole('columnheader', { name: /^cpu_cores \(proxy\)$/i })
		).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: /^Disk \(host\)$/i })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: /^CPU \(host\)$/i })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: /^RAM \(host\)$/i })).toBeInTheDocument();
		expect(
			screen.getByRole('columnheader', { name: /^Network RX\/TX totals \(host\)$/i })
		).toBeInTheDocument();

		expect(secondRow).toHaveTextContent('vm-def.flapjack.foo');
		expect(secondRow).toHaveTextContent('unhealthy');
		expect(
			screen.getByTestId('tenant-count-vm-aaaaaaaa-0002-0000-0000-000000000002')
		).toHaveTextContent('4');
		expect(
			screen.getByTestId('index-count-vm-aaaaaaaa-0002-0000-0000-000000000002')
		).toHaveTextContent('6');
		expect(thirdRow).toHaveTextContent('eu-central-1');
		expect(thirdRow).toHaveTextContent('hetzner');
		expect(thirdRow).toHaveTextContent('maintenance');
		expect(thirdRow).toHaveTextContent('unknown');
		expect(
			within(firstRow).getByTestId('kill-vm-vm-aaaaaaaa-0001-0000-0000-000000000001')
		).toBeInTheDocument();
		expect(
			within(secondRow).getByTestId('kill-vm-vm-aaaaaaaa-0002-0000-0000-000000000002')
		).toBeInTheDocument();
		expect(
			within(thirdRow).queryByTestId('kill-vm-vm-bbbbbbbb-0003-0000-0000-000000000003')
		).not.toBeInTheDocument();
		expect(within(thirdRow).getByText('remote')).toBeInTheDocument();
	});

	it('renders exact real host metrics beside proxy capacity values', async () => {
		const FleetPage = (await import('./+page.svelte')).default;
		const vm = VM_FIXTURES[0];

		render(FleetPage, {
			data: pageData({
				vms: [vm],
				hostMetricsByVmId: {
					[vm.id]: makeHostMetrics({ vm_id: vm.id })
				}
			}),
			form: null
		});

		expect(cellText(screen.getByTestId(`capacity-util-${vm.id}-disk_bytes`))).toBe('25%');
		expect(cellText(screen.getByTestId(`capacity-util-${vm.id}-cpu_cores`))).toBe('25%');
		expect(cellText(screen.getByTestId(`host-disk-${vm.id}`))).toBe('25%');
		expect(cellText(screen.getByTestId(`host-cpu-${vm.id}`))).toBe('12.5%');
		expect(cellText(screen.getByTestId(`host-ram-${vm.id}`))).toBe('75%');
		expect(cellText(screen.getByTestId(`host-net-${vm.id}`))).toBe(
			'RX total 1.0 KB / TX total 2.0 KB'
		);
	});

	it('renders deterministic host metric absence and invalid-total states', async () => {
		const FleetPage = (await import('./+page.svelte')).default;
		const [
			nullSampleVm,
			nullDiskVm,
			zeroDiskTotalVm,
			negativeDiskTotalVm,
			zeroRamTotalVm,
			negativeRamTotalVm
		] = [
			VM_FIXTURES[0],
			VM_FIXTURES[1],
			VM_FIXTURES[2],
			VM_FIXTURES[0],
			VM_FIXTURES[1],
			VM_FIXTURES[2]
		].map((vm, index) => ({
			...vm,
			id: `host-state-vm-${index + 1}`,
			hostname: `host-state-vm-${index + 1}.flapjack.foo`
		}));

		render(FleetPage, {
			data: pageData({
				vms: [
					nullSampleVm,
					nullDiskVm,
					zeroDiskTotalVm,
					negativeDiskTotalVm,
					zeroRamTotalVm,
					negativeRamTotalVm
				],
				hostMetricsByVmId: {
					[nullSampleVm.id]: null,
					[nullDiskVm.id]: makeHostMetrics({
						vm_id: nullDiskVm.id,
						disk_used_bytes: null,
						disk_total_bytes: null
					}),
					[zeroDiskTotalVm.id]: makeHostMetrics({
						vm_id: zeroDiskTotalVm.id,
						disk_used_bytes: 25,
						disk_total_bytes: 0
					}),
					[negativeDiskTotalVm.id]: makeHostMetrics({
						vm_id: negativeDiskTotalVm.id,
						disk_used_bytes: 25,
						disk_total_bytes: -100
					}),
					[zeroRamTotalVm.id]: makeHostMetrics({
						vm_id: zeroRamTotalVm.id,
						mem_used_bytes: 3,
						mem_total_bytes: 0
					}),
					[negativeRamTotalVm.id]: makeHostMetrics({
						vm_id: negativeRamTotalVm.id,
						mem_used_bytes: 3,
						mem_total_bytes: -4
					})
				}
			}),
			form: null
		});

		for (const testId of [
			`host-disk-${nullSampleVm.id}`,
			`host-cpu-${nullSampleVm.id}`,
			`host-ram-${nullSampleVm.id}`,
			`host-net-${nullSampleVm.id}`
		]) {
			expect(cellText(screen.getByTestId(testId))).toBe('No host data');
		}

		for (const vm of [nullDiskVm, zeroDiskTotalVm, negativeDiskTotalVm]) {
			expect(cellText(screen.getByTestId(`host-disk-${vm.id}`))).toBe('—');
			expect(cellText(screen.getByTestId(`host-cpu-${vm.id}`))).toBe('12.5%');
			expect(cellText(screen.getByTestId(`host-ram-${vm.id}`))).toBe('75%');
			expect(cellText(screen.getByTestId(`host-net-${vm.id}`))).toBe(
				'RX total 1.0 KB / TX total 2.0 KB'
			);
		}

		for (const vm of [zeroRamTotalVm, negativeRamTotalVm]) {
			expect(cellText(screen.getByTestId(`host-disk-${vm.id}`))).toBe('25%');
			expect(cellText(screen.getByTestId(`host-cpu-${vm.id}`))).toBe('12.5%');
			expect(cellText(screen.getByTestId(`host-ram-${vm.id}`))).toBe('—');
			expect(cellText(screen.getByTestId(`host-net-${vm.id}`))).toBe(
				'RX total 1.0 KB / TX total 2.0 KB'
			);
		}

		for (const cell of screen.getAllByTestId(/^host-/)) {
			expect(cell.textContent).not.toMatch(/\b0%|NaN%|Infinity%/);
		}
	});

	it('renders deterministic region rollups with weighted aggregate disk utilization', async () => {
		const FleetPage = (await import('./+page.svelte')).default;

		render(FleetPage, {
			data: pageData({ vms: VM_FIXTURES }),
			form: null
		});

		const euRollup = screen.getByTestId('region-rollup-eu-central-1');
		const usRollup = screen.getByTestId('region-rollup-us-east-1');
		const rollups = screen.getAllByTestId(/^region-rollup-/);

		expect(rollups[0]).toBe(euRollup);
		expect(rollups[1]).toBe(usRollup);
		expect(euRollup).toHaveTextContent('eu-central-1');
		expect(euRollup).toHaveTextContent('1 VM');
		expect(euRollup).toHaveTextContent('Aggregate disk utilization');
		expect(euRollup).toHaveTextContent('Unavailable');
		expect(usRollup).toHaveTextContent('us-east-1');
		expect(usRollup).toHaveTextContent('2 VMs');
		expect(usRollup).toHaveTextContent('Aggregate disk utilization');
		expect(usRollup).toHaveTextContent('40%');
	});

	it('renders replica placement roles per VM from the replicas join', async () => {
		const FleetPage = (await import('./+page.svelte')).default;

		render(FleetPage, {
			data: pageData({ vms: VM_FIXTURES, replicas: REPLICA_FIXTURES }),
			form: null
		});

		expect(screen.getByRole('columnheader', { name: /^Replica placement$/i })).toBeInTheDocument();

		// First VM is the primary for the seeded replica.
		const primaryCell = screen.getByTestId(
			'capacity-replicas-vm-aaaaaaaa-0001-0000-0000-000000000001'
		);
		expect(replicaCellLines(primaryCell)).toEqual([
			'Primary: 1',
			'Replica: 0',
			'Replica regions: eu-west-1'
		]);

		// Second VM hosts the replica copy.
		const replicaHostCell = screen.getByTestId(
			'capacity-replicas-vm-aaaaaaaa-0002-0000-0000-000000000002'
		);
		expect(replicaCellLines(replicaHostCell)).toEqual([
			'Primary: 0',
			'Replica: 1',
			'Hosts replica: eu-west-1'
		]);

		// Third VM has neither role.
		const noRoleCell = screen.getByTestId(
			'capacity-replicas-vm-bbbbbbbb-0003-0000-0000-000000000003'
		);
		expect(replicaCellLines(noRoleCell)).toEqual(['No replicas']);
	});

	it('renders unavailable placement instead of a false empty state on replica fetch failure', async () => {
		const FleetPage = (await import('./+page.svelte')).default;

		render(FleetPage, {
			data: pageData({ vms: VM_FIXTURES, replicaPlacementAvailable: false }),
			form: null
		});

		const cell = screen.getByTestId('capacity-replicas-vm-aaaaaaaa-0001-0000-0000-000000000001');
		expect(replicaCellLines(cell)).toEqual(['Replica placement unavailable']);
	});

	it('filters deployments by status', async () => {
		const FleetPage = (await import('./+page.svelte')).default;

		render(FleetPage, {
			data: pageData({ fleet: FLEET_FIXTURES }),
			form: null
		});

		// Select "running" status filter
		const statusFilter = screen.getByTestId('status-filter');
		await fireEvent.change(statusFilter, { target: { value: 'running' } });

		// Only running VMs should be visible in the table body
		const tableBody = screen.getByTestId('fleet-table-body');
		const rows = within(tableBody).getAllByRole('row');
		expect(rows).toHaveLength(2);

		// Verify every visible row actually has "running" status
		rows.forEach((row) => {
			expect(within(row).getByText('running')).toBeInTheDocument();
		});
	});

	it('filters deployments by provider', async () => {
		const FleetPage = (await import('./+page.svelte')).default;

		render(FleetPage, {
			data: pageData({ fleet: FLEET_FIXTURES }),
			form: null
		});

		// Select "hetzner" provider filter
		const providerFilter = screen.getByTestId('provider-filter');
		await fireEvent.change(providerFilter, { target: { value: 'hetzner' } });

		// Only Hetzner VMs should be visible (2 out of 5)
		const tableBody = screen.getByTestId('fleet-table-body');
		const rows = within(tableBody).getAllByRole('row');
		expect(rows).toHaveLength(2);

		// Verify every visible row actually has "hetzner" provider
		rows.forEach((row) => {
			expect(within(row).getByText('hetzner')).toBeInTheDocument();
		});
	});

	it('keeps filter options, filtered rows, and summary cards aligned with fleet data values', async () => {
		const FleetPage = (await import('./+page.svelte')).default;
		const fleetWithAdditionalValues: AdminFleetDeployment[] = [
			...FLEET_FIXTURES,
			makeDeployment({
				id: 'aaaaaaaa-0006-0000-0000-000000000006',
				vm_provider: 'gcp',
				status: 'maintenance',
				health_status: 'unknown'
			}),
			makeDeployment({
				id: 'aaaaaaaa-0007-0000-0000-000000000007',
				vm_provider: 'oci',
				status: 'running',
				health_status: 'healthy'
			})
		];

		render(FleetPage, {
			data: pageData({ fleet: fleetWithAdditionalValues }),
			form: null
		});

		const statusFilter = screen.getByTestId('status-filter') as HTMLSelectElement;
		const providerFilter = screen.getByTestId('provider-filter') as HTMLSelectElement;

		const statusValues = Array.from(statusFilter.options, (option) => option.value);
		const providerValues = Array.from(providerFilter.options, (option) => option.value);
		const providerLabels = Array.from(providerFilter.options, (option) => option.text);
		expect(statusValues).toContain('maintenance');
		expect(providerValues).toContain('gcp');
		expect(providerValues).toContain('oci');
		expect(providerLabels).toContain('AWS');
		expect(providerLabels).toContain('GCP');
		expect(providerLabels).toContain('OCI');

		// Summary cards should still reflect known status buckets while total tracks all deployments.
		expect(screen.getByTestId('total-deployments')).toHaveTextContent('7');
		expect(screen.getByTestId('running-count')).toHaveTextContent('3');

		await fireEvent.change(statusFilter, { target: { value: 'maintenance' } });
		await fireEvent.change(providerFilter, { target: { value: 'gcp' } });

		const tableBody = screen.getByTestId('fleet-table-body');
		const rows = within(tableBody).getAllByRole('row');
		expect(rows).toHaveLength(1);
		expect(within(rows[0]).getByText('maintenance')).toBeInTheDocument();
		expect(within(rows[0]).getByText('gcp')).toBeInTheDocument();
	});

	it('renders the kill error banner from a failed server action result', async () => {
		const FleetPage = (await import('./+page.svelte')).default;

		render(FleetPage, {
			data: pageData({ vms: VM_FIXTURES }),
			form: { error: 'Kill failed upstream' }
		});

		expect(screen.getByTestId('kill-error')).toHaveTextContent('Kill failed upstream');
	});
});

describe('Fleet health check', () => {
	it('healthCheckDeployment calls POST to correct endpoint', async () => {
		let capturedUrl = '';
		let capturedMethod = '';

		const { AdminClient } = await import('$lib/admin-client');
		const client = new AdminClient('http://localhost:3000', 'test-key');
		client.setFetch(async (input: string | URL | Request, init?: RequestInit) => {
			capturedUrl = typeof input === 'string' ? input : input.toString();
			capturedMethod = init?.method ?? 'GET';
			const body: HealthCheckResponse = {
				id: 'aaaaaaaa-0001-0000-0000-000000000001',
				health_status: 'healthy',
				last_health_check_at: '2026-02-21T12:00:00Z'
			};
			return new Response(JSON.stringify(body), { status: 200 });
		});

		const result = await client.healthCheckDeployment('aaaaaaaa-0001-0000-0000-000000000001');

		expect(capturedUrl).toBe(
			'http://localhost:3000/admin/deployments/aaaaaaaa-0001-0000-0000-000000000001/health-check'
		);
		expect(capturedMethod).toBe('POST');
		expect(result.health_status).toBe('healthy');
	});
});
