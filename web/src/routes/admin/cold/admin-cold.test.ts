import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/admin/cold') }
}));

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

interface ColdIndexFixture {
	customer_id: string;
	customer_name: string;
	tenant_id: string;
	snapshot_id: string;
	size_bytes: number;
	status: string;
	cold_since: string;
	object_key: string | null;
	last_accessed_at: string | null;
}

const COLD_FIXTURES: ColdIndexFixture[] = [
	{
		customer_id: 'aaaaaaaa-0001-0000-0000-000000000001',
		customer_name: 'Acme Corp',
		tenant_id: 'products',
		snapshot_id: 'bbbbbbbb-0001-0000-0000-000000000001',
		size_bytes: 1_073_741_824,
		status: 'completed',
		cold_since: '2026-01-15T12:00:00Z',
		object_key: null,
		last_accessed_at: null
	},
	{
		customer_id: 'aaaaaaaa-0002-0000-0000-000000000002',
		customer_name: 'Beta Labs',
		tenant_id: 'orders',
		snapshot_id: 'bbbbbbbb-0002-0000-0000-000000000002',
		size_bytes: 512_000,
		status: 'completed',
		cold_since: '2026-02-01T08:00:00Z',
		object_key: null,
		last_accessed_at: null
	}
];

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

describe('Admin cold storage page', () => {
	it('cold_index_list_renders_snapshot_data', async () => {
		const ColdPage = (await import('./+page.svelte')).default;

		render(ColdPage, {
			data: { environment: 'test', isAuthenticated: true, coldIndexes: COLD_FIXTURES }
		});

		// Verify page heading
		expect(screen.getByRole('heading', { name: 'Cold Storage' })).toBeInTheDocument();

		// Verify table renders all cold indexes
		const tableBody = screen.getByTestId('cold-table-body');
		expect(within(tableBody).getAllByRole('row')).toHaveLength(2);

		// Verify data content renders correctly
		expect(screen.getByText('products')).toBeInTheDocument();
		expect(screen.getByText('orders')).toBeInTheDocument();
		expect(screen.getByText('Acme Corp')).toBeInTheDocument();
		expect(screen.getByText('Beta Labs')).toBeInTheDocument();

		// Size should be displayed as human-readable
		expect(screen.getByText('1.00 GB')).toBeInTheDocument();
	});

	it('cold_restore_button_triggers_restore', async () => {
		const ColdPage = (await import('./+page.svelte')).default;

		render(ColdPage, {
			data: { environment: 'test', isAuthenticated: true, coldIndexes: COLD_FIXTURES }
		});

		// Find restore buttons
		const restoreButtons = screen.getAllByTestId('restore-button');
		expect(restoreButtons).toHaveLength(2);

		// Each button should be inside a form with the snapshot_id
		const firstRow = screen.getByTestId('cold-table-body').querySelectorAll('tr')[0];
		const form = firstRow.querySelector('form');
		expect(form).toBeTruthy();
		expect(form!.querySelector('input[name="snapshot_id"]')).toBeTruthy();
	});

	it('cold_page_shows_empty_state', async () => {
		const ColdPage = (await import('./+page.svelte')).default;

		render(ColdPage, {
			data: { environment: 'test', isAuthenticated: true, coldIndexes: [] }
		});

		expect(screen.getByText('No indexes in cold storage.')).toBeInTheDocument();
	});
});
