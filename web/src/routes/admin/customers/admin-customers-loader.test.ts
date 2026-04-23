import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

beforeEach(() => {
	process.env.ADMIN_KEY = 'test-admin-key';
});

afterEach(() => {
	delete process.env.ADMIN_KEY;
	vi.clearAllMocks();
});

/** Helper: build a mock fetch that routes admin API calls for loader tests. */
function mockAdminFetch(options: {
	tenants: Array<{ id: string; name: string; email: string; status: string; created_at: string }>;
	invoicesByTenant: Record<
		string,
		| Array<{
				id: string;
				status: string;
				created_at: string;
				period_start: string;
				period_end: string;
				subtotal_cents: number;
				total_cents: number;
				minimum_applied: boolean;
		  }>
		| 'error'
	>;
}) {
	return async (input: string | URL | Request) => {
		const url = typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;

		if (url.endsWith('/admin/tenants')) {
			return new Response(JSON.stringify(options.tenants), {
				status: 200,
				headers: { 'content-type': 'application/json' }
			});
		}

		// Match /admin/tenants/{id}/invoices
		const invoiceMatch = url.match(/\/admin\/tenants\/([^/]+)\/invoices$/);
		if (invoiceMatch) {
			const tenantId = invoiceMatch[1];
			const data = options.invoicesByTenant[tenantId];
			if (data === 'error') {
				return new Response('Service unavailable', { status: 500 });
			}
			return new Response(JSON.stringify(data ?? []), {
				status: 200,
				headers: { 'content-type': 'application/json' }
			});
		}

		return new Response('Not found', { status: 404 });
	};
}

const TENANT_A = {
	id: 'aaaaaaaa-0001-0000-0000-000000000001',
	name: 'Acme Corp',
	email: 'ops@acme.dev',
	status: 'active',
	created_at: '2026-02-10T12:00:00Z'
};

describe('Admin customers list loader', () => {
	it('returns latest invoice status per tenant from getTenantInvoices', async () => {
		const { load } = await import('./+page.server');

		const result = await load({
			fetch: mockAdminFetch({
				tenants: [TENANT_A],
				invoicesByTenant: {
					[TENANT_A.id]: [
						{
							id: 'inv-1',
							status: 'paid',
							created_at: '2026-01-15T00:00:00Z',
							period_start: '2026-01-01',
							period_end: '2026-01-31',
							subtotal_cents: 1000,
							total_cents: 1000,
							minimum_applied: false
						},
						{
							id: 'inv-2',
							status: 'failed',
							created_at: '2026-02-15T00:00:00Z',
							period_start: '2026-02-01',
							period_end: '2026-02-28',
							subtotal_cents: 2000,
							total_cents: 2000,
							minimum_applied: false
						}
					]
				}
			}),
			depends: vi.fn()
		} as never);

		const customers = (result as { customers: Array<{ last_invoice_status: string | null }> }).customers;
		// The most recent invoice (by created_at) has status 'failed'
		expect(customers[0].last_invoice_status).toBe('failed');
	});

	it('returns last_invoice_status "none" when tenant has no invoices', async () => {
		const { load } = await import('./+page.server');

		const result = await load({
			fetch: mockAdminFetch({
				tenants: [TENANT_A],
				invoicesByTenant: { [TENANT_A.id]: [] }
			}),
			depends: vi.fn()
		} as never);

		const customers = (result as { customers: Array<{ last_invoice_status: string | null }> }).customers;
		expect(customers[0].last_invoice_status).toBe('none');
	});

	it('returns last_invoice_status null when getTenantInvoices rejects', async () => {
		const { load } = await import('./+page.server');

		const result = await load({
			fetch: mockAdminFetch({
				tenants: [TENANT_A],
				invoicesByTenant: { [TENANT_A.id]: 'error' }
			}),
			depends: vi.fn()
		} as never);

		const customers = (result as { customers: Array<{ last_invoice_status: string | null }> }).customers;
		// Unavailable sentinel: null means the API call failed
		expect(customers[0].last_invoice_status).toBeNull();
	});

	it('returns index_count null instead of hardcoded 0', async () => {
		const { load } = await import('./+page.server');

		const result = await load({
			fetch: mockAdminFetch({
				tenants: [TENANT_A],
				invoicesByTenant: { [TENANT_A.id]: [] }
			}),
			depends: vi.fn()
		} as never);

		const customers = (result as { customers: Array<{ index_count: number | null }> }).customers;
		// No admin index-count endpoint exists; must be null, not fake 0
		expect(customers[0].index_count).toBeNull();
	});

	it('returns customers null when the tenant list cannot be loaded', async () => {
		const { load } = await import('./+page.server');

		const result = await load({
			fetch: async () => new Response('Service unavailable', { status: 503 }),
			depends: vi.fn()
		} as never);

		expect((result as { customers: null }).customers).toBeNull();
	});
});
