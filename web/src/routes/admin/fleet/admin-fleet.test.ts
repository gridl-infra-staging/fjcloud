import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';

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

import type { AdminFleetDeployment, HealthCheckResponse, VmInventoryItem } from '$lib/admin-client';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

function makeDeployment(overrides: Partial<AdminFleetDeployment> = {}): AdminFleetDeployment {
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

const FLEET_FIXTURES: AdminFleetDeployment[] = [
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

const VM_FIXTURES: VmInventoryItem[] = [
	{
		id: 'vm-aaaaaaaa-0001-0000-0000-000000000001',
		provider: 'aws',
		hostname: 'vm-abc.flapjack.foo',
		region: 'us-east-1',
		status: 'running',
		flapjack_url: 'http://127.0.0.1:9001',
		capacity: {},
		current_load: {},
		created_at: '2026-02-10T12:00:00Z',
		updated_at: '2026-02-21T10:00:00Z'
	}
];

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
			data: { environment: 'test', isAuthenticated: true, fleet: FLEET_FIXTURES, vms: [] },
			form: null
		});

		// Total VMs
		expect(screen.getByTestId('total-vms')).toHaveTextContent('5');
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
			data: { environment: 'test', isAuthenticated: true, fleet: FLEET_FIXTURES, vms: [] },
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
			data: { environment: 'test', isAuthenticated: true, fleet: [], vms: [] },
			form: null
		});

		expect(screen.getByTestId('total-vms')).toHaveTextContent('0');
		expect(screen.getByText(/no deployments/i)).toBeInTheDocument();
	});

	it('links VM infrastructure hostnames to the VM detail route', async () => {
		const FleetPage = (await import('./+page.svelte')).default;

		render(FleetPage, {
			data: { environment: 'test', isAuthenticated: true, fleet: [], vms: VM_FIXTURES },
			form: null
		});

		const hostnameLink = screen.getByRole('link', { name: 'vm-abc.flapjack.foo' });
		expect(hostnameLink).toHaveAttribute(
			'href',
			'/admin/fleet/vm-aaaaaaaa-0001-0000-0000-000000000001'
		);
	});

	it('filters deployments by status', async () => {
		const FleetPage = (await import('./+page.svelte')).default;

		render(FleetPage, {
			data: { environment: 'test', isAuthenticated: true, fleet: FLEET_FIXTURES, vms: [] },
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
			data: { environment: 'test', isAuthenticated: true, fleet: FLEET_FIXTURES, vms: [] },
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
			data: {
				environment: 'test',
				isAuthenticated: true,
				fleet: fleetWithAdditionalValues,
				vms: []
			},
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
		expect(screen.getByTestId('total-vms')).toHaveTextContent('7');
		expect(screen.getByTestId('running-count')).toHaveTextContent('3');

		await fireEvent.change(statusFilter, { target: { value: 'maintenance' } });
		await fireEvent.change(providerFilter, { target: { value: 'gcp' } });

		const tableBody = screen.getByTestId('fleet-table-body');
		const rows = within(tableBody).getAllByRole('row');
		expect(rows).toHaveLength(1);
		expect(within(rows[0]).getByText('maintenance')).toBeInTheDocument();
		expect(within(rows[0]).getByText('gcp')).toBeInTheDocument();
	});
});

describe('Fleet page server load', () => {
	it('loads fleet and VM data via admin client', async () => {
		const { load } = await import('./+page.server');

		const capturedPaths: string[] = [];
		const mockFetch = async (input: string | URL | Request) => {
			const path = typeof input === 'string' ? input : input.toString();
			capturedPaths.push(path);
			// Return fleet data for /fleet, empty array for /vms
			if (path.includes('/admin/fleet')) {
				return new Response(JSON.stringify(FLEET_FIXTURES), { status: 200 });
			}
			return new Response(JSON.stringify([]), { status: 200 });
		};

		const result = await load({
			fetch: mockFetch,
			depends: () => {}
		} as never);

		expect(capturedPaths.some((p) => p.includes('/admin/fleet'))).toBe(true);
		expect(capturedPaths.some((p) => p.includes('/admin/vms'))).toBe(true);
		expect(result!.fleet).toHaveLength(5);
		expect(result!.fleet[0].status).toBe('running');
		expect(result!.vms).toEqual([]);
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
		expect(result!.vms).toEqual([]);
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
