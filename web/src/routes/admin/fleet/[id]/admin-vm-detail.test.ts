import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/admin/fleet/aaaaaaaa-0001-0000-0000-000000000001') }
}));

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

const VM_DETAIL_FIXTURE = {
	vm: {
		id: 'aaaaaaaa-0001-0000-0000-000000000001',
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
			vm_id: 'aaaaaaaa-0001-0000-0000-000000000001',
			tier: 'active',
			resource_quota: {},
			created_at: '2026-02-15T12:00:00Z'
		},
		{
			customer_id: 'bbbbbbbb-0002-0000-0000-000000000002',
			tenant_id: 'orders',
			deployment_id: 'cccccccc-0002-0000-0000-000000000002',
			vm_id: 'aaaaaaaa-0001-0000-0000-000000000001',
			tier: 'active',
			resource_quota: { max_query_rps: 200 },
			created_at: '2026-02-16T12:00:00Z'
		}
	]
};

beforeEach(() => {
	process.env.ADMIN_KEY = 'test-admin-key';
});

afterEach(() => {
	cleanup();
	delete process.env.ADMIN_KEY;
	vi.clearAllMocks();
});

describe('VM detail page', () => {
	it('vm_detail_shows_per_index_breakdown', async () => {
		const VmDetailPage = (await import('./+page.svelte')).default;

		render(VmDetailPage, {
			data: { environment: 'test', isAuthenticated: true, ...VM_DETAIL_FIXTURE }
		});

		// VM info section renders all fields in the correct section
		const vmInfo = screen.getByTestId('vm-info-section');
		expect(within(vmInfo).getByText('vm-abc.flapjack.foo')).toBeInTheDocument();
		expect(within(vmInfo).getByText('us-east-1')).toBeInTheDocument();
		expect(within(vmInfo).getByText('aws')).toBeInTheDocument();
		expect(within(vmInfo).getByText('i-0abc123def456')).toBeInTheDocument();
		expect(within(vmInfo).getByText('AWS instance ID')).toBeInTheDocument();

		// Per-index breakdown table
		const indexTable = screen.getByTestId('tenant-breakdown-table');
		const rows = within(indexTable).getAllByRole('row');
		// header + 2 data rows
		expect(rows).toHaveLength(3);
		expect(screen.getByText('products')).toBeInTheDocument();
		expect(screen.getByText('orders')).toBeInTheDocument();
	});

	it('vm_detail_shows_utilization_bars', async () => {
		const VmDetailPage = (await import('./+page.svelte')).default;

		render(VmDetailPage, {
			data: { environment: 'test', isAuthenticated: true, ...VM_DETAIL_FIXTURE }
		});

		// Utilization bars should render with correct percentages
		// cpu: 2.5/4 = 62.5%, ram: 4096/8192 = 50%, disk: 45/100 = 45%
		const cpuBar = screen.getByTestId('util-bar-cpu_cores');
		expect(cpuBar).toBeInTheDocument();
		expect(cpuBar.textContent).toContain('63%');

		const ramBar = screen.getByTestId('util-bar-ram_mb');
		expect(ramBar).toBeInTheDocument();
		expect(ramBar.textContent).toContain('50%');

		const diskBar = screen.getByTestId('util-bar-disk_gb');
		expect(diskBar).toBeInTheDocument();
		expect(diskBar.textContent).toContain('45%');
	});
});

describe('VM detail page server load', () => {
	it('loads vm detail via admin client getVmDetail()', async () => {
		const { load } = await import('./+page.server');

		let capturedPath = '';
		const mockFetch = async (input: string | URL | Request) => {
			capturedPath = typeof input === 'string' ? input : input.toString();
			return new Response(JSON.stringify(VM_DETAIL_FIXTURE), { status: 200 });
		};

		const result = await load({
			fetch: mockFetch,
			params: { id: 'aaaaaaaa-0001-0000-0000-000000000001' },
			depends: () => {}
		} as never);

		expect(capturedPath).toContain('/admin/vms/aaaaaaaa-0001-0000-0000-000000000001');
		expect(result!.vm.hostname).toBe('vm-abc.flapjack.foo');
		expect(result!.tenants).toHaveLength(2);
	});
});
