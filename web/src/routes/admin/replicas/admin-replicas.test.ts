import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/admin/replicas') }
}));

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

import type { AdminReplicaEntry } from '$lib/admin-client';

function makeReplica(overrides: Partial<AdminReplicaEntry> = {}): AdminReplicaEntry {
	return {
		id: 'aaaaaaaa-0001-0000-0000-000000000001',
		customer_id: 'cccccccc-0001-0000-0000-000000000001',
		tenant_id: 'products',
		replica_region: 'eu-central-1',
		status: 'active',
		lag_ops: 12,
		primary_vm_id: 'dddddddd-0001-0000-0000-000000000001',
		primary_vm_hostname: 'vm-aws-1.flapjack.foo',
		primary_vm_region: 'us-east-1',
		replica_vm_id: 'eeeeeeee-0001-0000-0000-000000000001',
		replica_vm_hostname: 'vm-hetzner-1.flapjack.foo',
		created_at: '2026-02-20T12:00:00Z',
		updated_at: '2026-02-22T10:00:00Z',
		...overrides
	};
}

const REPLICA_FIXTURES: AdminReplicaEntry[] = [
	makeReplica({
		id: 'aaaaaaaa-0001-0000-0000-000000000001',
		tenant_id: 'products',
		replica_region: 'eu-central-1',
		status: 'active',
		lag_ops: 12,
		primary_vm_region: 'us-east-1'
	}),
	makeReplica({
		id: 'aaaaaaaa-0002-0000-0000-000000000002',
		tenant_id: 'orders',
		replica_region: 'us-east-1',
		status: 'syncing',
		lag_ops: 340,
		primary_vm_hostname: 'vm-hetzner-1.flapjack.foo',
		primary_vm_region: 'eu-central-1',
		replica_vm_hostname: 'vm-aws-1.flapjack.foo'
	}),
	makeReplica({
		id: 'aaaaaaaa-0003-0000-0000-000000000003',
		tenant_id: 'logs',
		replica_region: 'eu-north-1',
		status: 'failed',
		lag_ops: 0,
		primary_vm_region: 'us-east-1'
	})
];

beforeEach(() => {
	process.env.ADMIN_KEY = 'test-admin-key';
});

afterEach(() => {
	cleanup();
	delete process.env.ADMIN_KEY;
	vi.clearAllMocks();
});

describe('Admin replicas page', () => {
	it('renders summary cards with correct counts', async () => {
		const ReplicasPage = (await import('./+page.svelte')).default;

		render(ReplicasPage, {
			data: { environment: 'test', isAuthenticated: true, replicas: REPLICA_FIXTURES }
		});

		expect(screen.getByTestId('total-replicas')).toHaveTextContent('3');
		expect(screen.getByTestId('active-count')).toHaveTextContent('1');
		expect(screen.getByTestId('syncing-count')).toHaveTextContent('1');
		expect(screen.getByTestId('failed-count')).toHaveTextContent('1');
	});

	it('renders replica table with all rows', async () => {
		const ReplicasPage = (await import('./+page.svelte')).default;

		render(ReplicasPage, {
			data: { environment: 'test', isAuthenticated: true, replicas: REPLICA_FIXTURES }
		});

		expect(screen.getByRole('columnheader', { name: /^Index$/i })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: /^Status$/i })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: /^Replica Region$/i })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: /^Lag$/i })).toBeInTheDocument();

		const rows = screen.getAllByRole('row');
		// header + 3 data rows
		expect(rows.length).toBe(4);

		expect(screen.getByText('products')).toBeInTheDocument();
		expect(screen.getByText('orders')).toBeInTheDocument();
		expect(screen.getByText('logs')).toBeInTheDocument();
	});

	it('filters replicas by status', async () => {
		const ReplicasPage = (await import('./+page.svelte')).default;

		render(ReplicasPage, {
			data: { environment: 'test', isAuthenticated: true, replicas: REPLICA_FIXTURES }
		});

		const statusFilter = screen.getByTestId('status-filter');
		await fireEvent.change(statusFilter, { target: { value: 'active' } });

		const tableBody = screen.getByTestId('replicas-table-body');
		const rows = within(tableBody).getAllByRole('row');
		expect(rows).toHaveLength(1);
		expect(within(rows[0]).getByText('products')).toBeInTheDocument();
	});

	it('syncing-count summary card includes legacy replicating replicas', async () => {
		const ReplicasPage = (await import('./+page.svelte')).default;

		render(ReplicasPage, {
			data: {
				environment: 'test',
				isAuthenticated: true,
				replicas: [
					makeReplica({
						id: 'aaaaaaaa-0001-0000-0000-000000000001',
						tenant_id: 'products',
						status: 'active'
					}),
					makeReplica({
						id: 'aaaaaaaa-0002-0000-0000-000000000002',
						tenant_id: 'orders',
						status: 'syncing'
					}),
					makeReplica({
						id: 'aaaaaaaa-0003-0000-0000-000000000003',
						tenant_id: 'logs',
						status: 'replicating'
					})
				]
			}
		});

		// syncing-count must include both 'syncing' and legacy 'replicating'
		expect(screen.getByTestId('syncing-count')).toHaveTextContent('2');
		expect(screen.getByTestId('active-count')).toHaveTextContent('1');
		expect(screen.getByTestId('failed-count')).toHaveTextContent('0');
	});

	it('syncing filter includes legacy replicating status', async () => {
		const ReplicasPage = (await import('./+page.svelte')).default;

		render(ReplicasPage, {
			data: {
				environment: 'test',
				isAuthenticated: true,
				replicas: [
					makeReplica({
						id: 'aaaaaaaa-0001-0000-0000-000000000001',
						tenant_id: 'products',
						status: 'active'
					}),
					makeReplica({
						id: 'aaaaaaaa-0002-0000-0000-000000000002',
						tenant_id: 'orders',
						status: 'replicating'
					})
				]
			}
		});

		const statusFilter = screen.getByTestId('status-filter');
		await fireEvent.change(statusFilter, { target: { value: 'syncing' } });

		const tableBody = screen.getByTestId('replicas-table-body');
		const rows = within(tableBody).getAllByRole('row');
		expect(rows).toHaveLength(1);
		expect(within(rows[0]).getByText('orders')).toBeInTheDocument();
		expect(screen.queryByText('products')).not.toBeInTheDocument();
	});

	it('renders empty state when no replicas exist', async () => {
		const ReplicasPage = (await import('./+page.svelte')).default;

		render(ReplicasPage, {
			data: { environment: 'test', isAuthenticated: true, replicas: [] }
		});

		expect(screen.getByTestId('total-replicas')).toHaveTextContent('0');
		expect(screen.getByText(/no replicas/i)).toBeInTheDocument();
	});
});

describe('Admin replicas server load', () => {
	it('loads replicas via admin client getReplicas()', async () => {
		const { load } = await import('./+page.server');

		let capturedPath = '';
		const mockFetch = async (input: string | URL | Request) => {
			capturedPath = typeof input === 'string' ? input : input.toString();
			return new Response(JSON.stringify(REPLICA_FIXTURES), { status: 200 });
		};

		const result = await load({
			fetch: mockFetch,
			depends: () => {}
		} as never);

		expect(capturedPath).toContain('/admin/replicas');
		expect(result!.replicas).toHaveLength(3);
		expect(result!.replicas[0].status).toBe('active');
	});

	it('returns empty array on API error', async () => {
		const { load } = await import('./+page.server');

		const mockFetch = async () => {
			return new Response('Internal Server Error', { status: 500 });
		};

		const result = await load({
			fetch: mockFetch,
			depends: () => {}
		} as never);

		expect(result!.replicas).toEqual([]);
	});
});
