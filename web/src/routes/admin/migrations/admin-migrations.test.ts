import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/admin/migrations') }
}));

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

import type { MigrationStatus } from '$lib/admin-client';

type AdminMigrationFixture = {
	id: string;
	index_name: string;
	customer_id: string;
	source_vm_id: string;
	dest_vm_id: string;
	status: MigrationStatus;
	requested_by: string;
	started_at: string;
	completed_at: string | null;
	error: string | null;
	metadata: Record<string, unknown>;
};

const ACTIVE_MIGRATIONS: AdminMigrationFixture[] = [
	{
		id: 'aaaaaaaa-0001-0000-0000-000000000001',
		index_name: 'products',
		customer_id: 'bbbbbbbb-0001-0000-0000-000000000001',
		source_vm_id: 'cccccccc-0001-0000-0000-000000000001',
		dest_vm_id: 'dddddddd-0001-0000-0000-000000000001',
		status: 'replicating',
		requested_by: 'scheduler',
		started_at: '2026-02-22T10:00:00Z',
		completed_at: null,
		error: null,
		metadata: {}
	}
];

const RECENT_MIGRATIONS: AdminMigrationFixture[] = [
	{
		id: 'aaaaaaaa-0002-0000-0000-000000000002',
		index_name: 'orders',
		customer_id: 'bbbbbbbb-0002-0000-0000-000000000002',
		source_vm_id: 'cccccccc-0002-0000-0000-000000000002',
		dest_vm_id: 'dddddddd-0002-0000-0000-000000000002',
		status: 'completed',
		requested_by: 'admin',
		started_at: '2026-02-21T09:00:00Z',
		completed_at: '2026-02-21T09:10:00Z',
		error: null,
		metadata: {}
	},
	{
		id: 'aaaaaaaa-0003-0000-0000-000000000003',
		index_name: 'logs',
		customer_id: 'bbbbbbbb-0003-0000-0000-000000000003',
		source_vm_id: 'cccccccc-0003-0000-0000-000000000003',
		dest_vm_id: 'dddddddd-0003-0000-0000-000000000003',
		status: 'failed',
		requested_by: 'drain',
		started_at: '2026-02-20T08:00:00Z',
		completed_at: '2026-02-20T08:15:00Z',
		error: 'destination timeout',
		metadata: {}
	}
];

beforeEach(() => {
	process.env.ADMIN_KEY = 'test-admin-key';
});

afterEach(() => {
	cleanup();
	delete process.env.ADMIN_KEY;
	vi.clearAllMocks();
});

describe('Admin migrations page', () => {
	it('migration_list_renders_active_and_recent', async () => {
		const MigrationsPage = (await import('./+page.svelte')).default;

		render(MigrationsPage, {
			data: {
				activeMigrations: ACTIVE_MIGRATIONS,
				recentMigrations: RECENT_MIGRATIONS
			}
		});

		expect(screen.getByRole('heading', { name: 'Migration Management' })).toBeInTheDocument();
		expect(screen.getByRole('heading', { name: 'Active Migrations' })).toBeInTheDocument();
		expect(screen.getByRole('heading', { name: 'Recent Migrations' })).toBeInTheDocument();

		const activeRows = within(screen.getByTestId('active-migrations-table')).getAllByRole('row');
		expect(activeRows).toHaveLength(2);
		expect(screen.getByText('products')).toBeInTheDocument();
		expect(screen.getByText('replicating')).toBeInTheDocument();

		const recentRows = within(screen.getByTestId('recent-migrations-table')).getAllByRole('row');
		expect(recentRows).toHaveLength(3);
		expect(screen.getByText('orders')).toBeInTheDocument();
		expect(screen.getByText('completed')).toBeInTheDocument();
		expect(screen.getByText('logs')).toBeInTheDocument();
		expect(screen.getByText('failed')).toBeInTheDocument();
	});

	it('migration_trigger_submits_form', async () => {
		const { actions } = await import('./+page.server');

		let capturedUrl = '';
		let capturedMethod = '';
		let capturedBody = '';

		const request = new Request('http://localhost/admin/migrations?/trigger', {
			method: 'POST',
			body: new URLSearchParams({
				index_name: 'products',
				dest_vm_id: 'dddddddd-0001-0000-0000-000000000001'
			})
		});

		const result = await actions.trigger({
			request,
			fetch: async (input: string | URL | Request, init?: RequestInit) => {
				capturedUrl = typeof input === 'string' ? input : input.toString();
				capturedMethod = init?.method ?? 'GET';
				capturedBody = String(init?.body ?? '');
				return new Response(
					JSON.stringify({
						migration_id: 'aaaaaaaa-0001-0000-0000-000000000001',
						status: 'started'
					}),
					{ status: 202 }
				);
			}
		} as never);

		expect(capturedUrl).toContain('/admin/migrations');
		expect(capturedMethod).toBe('POST');
		expect(capturedBody).toContain('"index_name":"products"');
		expect(capturedBody).toContain('"dest_vm_id":"dddddddd-0001-0000-0000-000000000001"');
		expect(result).toEqual({
			success: true,
			message: 'Migration started',
			migrationId: 'aaaaaaaa-0001-0000-0000-000000000001'
		});
	});
});
