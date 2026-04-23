import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';

vi.mock('$app/forms', () => ({
	applyAction: vi.fn(),
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	invalidate: vi.fn()
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/admin/billing') }
}));

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

interface BillingInvoice {
	id: string;
	customer_id: string;
	customer_name: string;
	customer_email: string;
	period_start: string;
	period_end: string;
	subtotal_cents: number;
	total_cents: number;
	status: string;
	minimum_applied: boolean;
	created_at: string;
}

const INVOICES_FIXTURE: BillingInvoice[] = [
	{
		id: 'inv-0001',
		customer_id: 'cust-0001',
		customer_name: 'Acme Corp',
		customer_email: 'ops@acme.dev',
		period_start: '2026-02-01',
		period_end: '2026-02-28',
		subtotal_cents: 12000,
		total_cents: 12000,
		status: 'paid',
		minimum_applied: false,
		created_at: '2026-03-01T00:00:00Z'
	},
	{
		id: 'inv-0002',
		customer_id: 'cust-0002',
		customer_name: 'Beta Labs',
		customer_email: 'billing@beta.dev',
		period_start: '2026-02-01',
		period_end: '2026-02-28',
		subtotal_cents: 8500,
		total_cents: 8500,
		status: 'failed',
		minimum_applied: false,
		created_at: '2026-03-01T00:00:00Z'
	},
	{
		id: 'inv-0003',
		customer_id: 'cust-0003',
		customer_name: 'Gamma Inc',
		customer_email: 'team@gamma.dev',
		period_start: '2026-02-01',
		period_end: '2026-02-28',
		subtotal_cents: 25000,
		total_cents: 25000,
		status: 'draft',
		minimum_applied: false,
		created_at: '2026-03-01T00:00:00Z'
	},
	{
		id: 'inv-0004',
		customer_id: 'cust-0001',
		customer_name: 'Acme Corp',
		customer_email: 'ops@acme.dev',
		period_start: '2026-02-01',
		period_end: '2026-02-28',
		subtotal_cents: 3200,
		total_cents: 3200,
		status: 'finalized',
		minimum_applied: false,
		created_at: '2026-03-01T00:00:00Z'
	},
	{
		id: 'inv-0005',
		customer_id: 'cust-0004',
		customer_name: 'Delta Co',
		customer_email: 'pay@delta.dev',
		period_start: '2026-02-01',
		period_end: '2026-02-28',
		subtotal_cents: 15000,
		total_cents: 15000,
		status: 'paid',
		minimum_applied: false,
		created_at: '2026-03-01T00:00:00Z'
	}
];

beforeEach(() => {
	process.env.ADMIN_KEY = 'test-admin-key';
});

afterEach(() => {
	cleanup();
	delete process.env.ADMIN_KEY;
	vi.clearAllMocks();
	vi.useRealTimers();
});

describe('Billing dashboard', () => {
	it('shows summary cards with correct invoice counts by status', async () => {
		const BillingPage = (await import('./+page.svelte')).default;

		render(BillingPage, {
			data: { invoices: INVOICES_FIXTURE }
		});

		// Summary cards: total, paid, failed, pending (draft + finalized)
		expect(screen.getByTestId('total-invoices')).toHaveTextContent('5');
		expect(screen.getByTestId('paid-count')).toHaveTextContent('2');
		expect(screen.getByTestId('failed-count')).toHaveTextContent('1');
		expect(screen.getByTestId('pending-count')).toHaveTextContent('2');
	});

	it('renders failed invoices table with customer info and amount', async () => {
		const BillingPage = (await import('./+page.svelte')).default;

		render(BillingPage, {
			data: { invoices: INVOICES_FIXTURE }
		});

		const failedSection = screen.getByTestId('failed-invoices-section');
		const rows = within(failedSection).getAllByRole('row');
		// header + 1 failed invoice
		expect(rows).toHaveLength(2);

		// Verify customer info is visible
		expect(within(failedSection).getByText('Beta Labs')).toBeInTheDocument();
		expect(within(failedSection).getByText('billing@beta.dev')).toBeInTheDocument();
		// Amount formatted as dollars
		expect(within(failedSection).getByText('$85.00')).toBeInTheDocument();
	});

	it('renders draft invoices table with bulk finalize button', async () => {
		const BillingPage = (await import('./+page.svelte')).default;

		render(BillingPage, {
			data: { invoices: INVOICES_FIXTURE }
		});

		const draftSection = screen.getByTestId('draft-invoices-section');
		const rows = within(draftSection).getAllByRole('row');
		// header + 1 draft invoice
		expect(rows).toHaveLength(2);

		expect(within(draftSection).getByText('Gamma Inc')).toBeInTheDocument();
		expect(within(draftSection).getByText('$250.00')).toBeInTheDocument();

		// Bulk finalize button exists
		expect(screen.getByRole('button', { name: /finalize/i })).toBeInTheDocument();
	});

	it('renders top-page success feedback from form.message', async () => {
		const BillingPage = (await import('./+page.svelte')).default;

		render(BillingPage, {
			data: { invoices: INVOICES_FIXTURE },
			form: { message: 'Billing complete: 2 invoices created, 1 skipped' }
		});

		expect(screen.getByText('Billing complete: 2 invoices created, 1 skipped')).toBeInTheDocument();
	});

	it('renders top-page error feedback from form.error', async () => {
		const BillingPage = (await import('./+page.svelte')).default;

		render(BillingPage, {
			data: { invoices: INVOICES_FIXTURE },
			form: { error: 'Bulk finalize failed: inv-001: upstream error' }
		});

		expect(screen.getByText('Bulk finalize failed: inv-001: upstream error')).toBeInTheDocument();
	});

	it('defaults the billing month input to the local calendar month', async () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-03-01T00:30:00Z'));

		const BillingPage = (await import('./+page.svelte')).default;

		render(BillingPage, {
			data: { invoices: INVOICES_FIXTURE }
		});

		await fireEvent.click(screen.getByTestId('run-billing-button'));

		expect(screen.getByLabelText('Billing month')).toHaveValue('2026-02');
	});
});

describe('Billing page server load', () => {
	it('aggregates invoices across all tenants', async () => {
		const { load } = await import('./+page.server');

		const tenants = [
			{ id: 'cust-0001', name: 'Acme Corp', email: 'ops@acme.dev', status: 'active', created_at: '2026-01-01T00:00:00Z' },
			{ id: 'cust-0002', name: 'Beta Labs', email: 'billing@beta.dev', status: 'active', created_at: '2026-01-01T00:00:00Z' }
		];

		const invoicesByCust: Record<string, unknown[]> = {
			'cust-0001': [
				{ id: 'inv-001', period_start: '2026-02-01', period_end: '2026-02-28', subtotal_cents: 5000, total_cents: 5000, status: 'paid', minimum_applied: false, created_at: '2026-03-01T00:00:00Z' }
			],
			'cust-0002': [
				{ id: 'inv-002', period_start: '2026-02-01', period_end: '2026-02-28', subtotal_cents: 3000, total_cents: 3000, status: 'draft', minimum_applied: false, created_at: '2026-03-01T00:00:00Z' }
			]
		};

		const mockFetch = async (input: string | URL | Request) => {
			const url = typeof input === 'string' ? input : input.toString();
			if (url.includes('/admin/tenants') && !url.includes('/invoices')) {
				return new Response(JSON.stringify(tenants), { status: 200 });
			}
			for (const custId of Object.keys(invoicesByCust)) {
				if (url.includes(`/admin/tenants/${custId}/invoices`)) {
					return new Response(JSON.stringify(invoicesByCust[custId]), { status: 200 });
				}
			}
			return new Response('Not Found', { status: 404 });
		};

		const result = await load({
			fetch: mockFetch,
			depends: () => {}
		} as never);

		expect(result!.invoices).toHaveLength(2);
		// Each invoice should be enriched with customer name and email
		const paidInv = result!.invoices.find((i: BillingInvoice) => i.status === 'paid');
		expect(paidInv.customer_name).toBe('Acme Corp');
		expect(paidInv.customer_email).toBe('ops@acme.dev');
	});

	it('returns empty invoices array on API error', async () => {
		const { load } = await import('./+page.server');

		const mockFetch = async () => new Response('Internal Server Error', { status: 500 });

		const result = await load({
			fetch: mockFetch,
			depends: () => {}
		} as never);

		expect(result!.invoices).toEqual([]);
	});

	it('returns invoices in deterministic route-owned order despite out-of-order tenant responses', async () => {
		const { load } = await import('./+page.server');

		const tenants = [
			{ id: 'tenant-acme', name: 'Acme Corp', email: 'ops@acme.dev', status: 'active', created_at: '2026-01-01T00:00:00Z' },
			{ id: 'tenant-beta', name: 'Beta Labs', email: 'billing@beta.dev', status: 'active', created_at: '2026-01-01T00:00:00Z' },
			{ id: 'tenant-gamma', name: 'Gamma Inc', email: 'team@gamma.dev', status: 'active', created_at: '2026-01-01T00:00:00Z' }
		];

		const invoicesByTenant: Record<string, unknown[]> = {
			'tenant-acme': [
				{ id: 'inv-100', period_start: '2026-02-01', period_end: '2026-02-28', subtotal_cents: 5000, total_cents: 5000, status: 'draft', minimum_applied: false, created_at: '2026-03-02T09:00:00Z' },
				{ id: 'inv-090', period_start: '2026-02-01', period_end: '2026-02-28', subtotal_cents: 3000, total_cents: 3000, status: 'failed', minimum_applied: false, created_at: '2026-03-02T09:00:00Z' }
			],
			'tenant-beta': [
				{ id: 'inv-200', period_start: '2026-02-01', period_end: '2026-02-28', subtotal_cents: 8000, total_cents: 8000, status: 'paid', minimum_applied: false, created_at: '2026-03-02T09:00:00Z' }
			],
			'tenant-gamma': [
				{ id: 'inv-300', period_start: '2026-02-01', period_end: '2026-02-28', subtotal_cents: 12000, total_cents: 12000, status: 'paid', minimum_applied: false, created_at: '2026-03-03T12:00:00Z' }
			]
		};

		const responseDelayMs: Record<string, number> = {
			'tenant-acme': 20,
			'tenant-beta': 1,
			'tenant-gamma': 10
		};

		const mockFetch = async (input: string | URL | Request) => {
			const url = typeof input === 'string' ? input : input.toString();

			if (url.includes('/admin/tenants') && !url.includes('/invoices')) {
				return new Response(JSON.stringify(tenants), { status: 200 });
			}

			const match = url.match(/\/admin\/tenants\/([^/]+)\/invoices/);
			if (!match) {
				return new Response('Not Found', { status: 404 });
			}

			const tenantId = match[1];
			await new Promise((resolve) => setTimeout(resolve, responseDelayMs[tenantId] ?? 0));
			return new Response(JSON.stringify(invoicesByTenant[tenantId] ?? []), { status: 200 });
		};

		const result = await load({
			fetch: mockFetch,
			depends: () => {}
		} as never);

		expect(result!.invoices.map((invoice: BillingInvoice) => `${invoice.id}:${invoice.customer_name}`)).toEqual([
			'inv-300:Gamma Inc',
			'inv-090:Acme Corp',
			'inv-100:Acme Corp',
			'inv-200:Beta Labs'
		]);
		expect(result!.invoices[1].customer_email).toBe('ops@acme.dev');
	});
});

describe('Admin client billing methods', () => {
	it('runBatchBilling calls POST /admin/billing/run with month', async () => {
		let capturedUrl = '';
		let capturedMethod = '';
		let capturedBody = '';

		const { AdminClient } = await import('$lib/admin-client');
		const client = new AdminClient('http://localhost:3000', 'test-key');
		client.setFetch(async (input: string | URL | Request, init?: RequestInit) => {
			capturedUrl = typeof input === 'string' ? input : input.toString();
			capturedMethod = init?.method ?? 'GET';
			capturedBody = init?.body as string ?? '';
			return new Response(
				JSON.stringify({
					month: '2026-02',
					invoices_created: 3,
					invoices_skipped: 1,
					results: []
				}),
				{ status: 200 }
			);
		});

		const result = await client.runBatchBilling('2026-02');

		expect(capturedUrl).toBe('http://localhost:3000/admin/billing/run');
		expect(capturedMethod).toBe('POST');
		expect(JSON.parse(capturedBody)).toEqual({ month: '2026-02' });
		expect(result!.invoices_created).toBe(3);
	});

	it('finalizeInvoice calls POST /admin/invoices/:id/finalize', async () => {
		let capturedUrl = '';
		let capturedMethod = '';

		const { AdminClient } = await import('$lib/admin-client');
		const client = new AdminClient('http://localhost:3000', 'test-key');
		client.setFetch(async (input: string | URL | Request, init?: RequestInit) => {
			capturedUrl = typeof input === 'string' ? input : input.toString();
			capturedMethod = init?.method ?? 'GET';
			return new Response(JSON.stringify({ id: 'inv-001', status: 'finalized' }), { status: 200 });
		});

		const result = await client.finalizeInvoice('inv-001');

		expect(capturedUrl).toBe('http://localhost:3000/admin/invoices/inv-001/finalize');
		expect(capturedMethod).toBe('POST');
		expect(result.status).toBe('finalized');
	});
});

describe('Billing page server actions', () => {
	it('runBilling action calls runBatchBilling with month from form data', async () => {
		const { actions } = await import('./+page.server');

		let capturedUrl = '';
		let capturedMethod = '';
		let capturedBody = '';

		const formData = new FormData();
		formData.set('month', '2026-02');

		const result = await actions.runBilling({
			request: new Request('http://localhost/admin/billing?/runBilling', {
				method: 'POST',
				body: formData
			}),
			fetch: async (input: string | URL | Request, init?: RequestInit) => {
				capturedUrl = typeof input === 'string' ? input : input.toString();
				capturedMethod = init?.method ?? 'GET';
				capturedBody = (init?.body as string) ?? '';
				return new Response(
					JSON.stringify({
						month: '2026-02',
						invoices_created: 3,
						invoices_skipped: 1,
						results: []
					}),
					{ status: 200 }
				);
			}
		} as never);

		expect(capturedUrl).toContain('/admin/billing/run');
		expect(capturedMethod).toBe('POST');
		expect(JSON.parse(capturedBody)).toEqual({ month: '2026-02' });
		expect(result).toEqual(
			expect.objectContaining({
				success: true,
				message: 'Billing complete: 3 invoices created, 1 skipped'
			})
		);
	});

	it('bulkFinalize action calls finalizeInvoice for each provided invoice ID', async () => {
		const { actions } = await import('./+page.server');

		const capturedUrls: string[] = [];

		const formData = new FormData();
		formData.append('invoice_ids', 'inv-001');
		formData.append('invoice_ids', 'inv-002');

		const result = await actions.bulkFinalize({
			request: new Request('http://localhost/admin/billing?/bulkFinalize', {
				method: 'POST',
				body: formData
			}),
			fetch: async (input: string | URL | Request) => {
				capturedUrls.push(typeof input === 'string' ? input : input.toString());
				return new Response(
					JSON.stringify({ id: 'inv-001', status: 'finalized' }),
					{ status: 200 }
				);
			}
		} as never);

		expect(capturedUrls).toHaveLength(2);
		expect(capturedUrls[0]).toContain('/admin/invoices/inv-001/finalize');
		expect(capturedUrls[1]).toContain('/admin/invoices/inv-002/finalize');
		expect(result).toEqual(
			expect.objectContaining({
				success: true,
				finalized: 2,
				message: 'Bulk finalize complete: 2 invoices finalized'
			})
		);
	});

	it('runBilling action returns error when month is missing', async () => {
		const { actions } = await import('./+page.server');

		const formData = new FormData();

		const result = await actions.runBilling({
			request: new Request('http://localhost/admin/billing?/runBilling', {
				method: 'POST',
				body: formData
			}),
			fetch: async () => new Response('', { status: 200 })
		} as never);

		expect(result).toEqual(
			expect.objectContaining({ status: 400 })
		);
	});

	it('runBilling action rejects malformed month input before calling the admin API', async () => {
		const { actions } = await import('./+page.server');

		const formData = new FormData();
		formData.set('month', '2026-13');

		const fetchSpy = vi.fn(async () => new Response('', { status: 200 }));
		const result = await actions.runBilling({
			request: new Request('http://localhost/admin/billing?/runBilling', {
				method: 'POST',
				body: formData
			}),
			fetch: fetchSpy
		} as never);

		expect(fetchSpy).not.toHaveBeenCalled();
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					success: false,
					error: 'Month must use YYYY-MM format'
				})
			})
		);
	});

	it('runBilling action returns renderable error when upstream billing run fails', async () => {
		const { actions } = await import('./+page.server');

		const formData = new FormData();
		formData.set('month', '2026-02');

		const result = await actions.runBilling({
			request: new Request('http://localhost/admin/billing?/runBilling', {
				method: 'POST',
				body: formData
			}),
			fetch: async () => new Response(JSON.stringify({ error: 'upstream failed' }), { status: 500 })
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 500,
				data: expect.objectContaining({
					success: false,
					error: 'upstream failed'
				})
			})
		);
	});

	it('bulkFinalize action returns renderable error when finalize calls fail', async () => {
		const { actions } = await import('./+page.server');

		const formData = new FormData();
		formData.append('invoice_ids', 'inv-001');
		formData.append('invoice_ids', 'inv-002');

		const result = await actions.bulkFinalize({
			request: new Request('http://localhost/admin/billing?/bulkFinalize', {
				method: 'POST',
				body: formData
			}),
			fetch: async () =>
				new Response(JSON.stringify({ error: 'finalize endpoint unavailable' }), { status: 500 })
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 500,
				data: expect.objectContaining({
					success: false,
					error: 'Bulk finalize failed: inv-001: finalize endpoint unavailable; inv-002: finalize endpoint unavailable'
				})
			})
		);
	});

	it('bulkFinalize action keeps partial-success errors renderable without failing the action', async () => {
		const { actions } = await import('./+page.server');

		const formData = new FormData();
		formData.append('invoice_ids', 'inv-001');
		formData.append('invoice_ids', 'inv-002');

		const result = await actions.bulkFinalize({
			request: new Request('http://localhost/admin/billing?/bulkFinalize', {
				method: 'POST',
				body: formData
			}),
			fetch: async (input: string | URL | Request) => {
				const url = typeof input === 'string' ? input : input.toString();
				if (url.includes('/admin/invoices/inv-001/finalize')) {
					return new Response(JSON.stringify({ id: 'inv-001', status: 'finalized' }), {
						status: 200
					});
				}

				return new Response(JSON.stringify({ error: 'finalize endpoint unavailable' }), {
					status: 500
				});
			}
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				success: false,
				finalized: 1,
				error: 'Bulk finalize partially failed after finalizing 1 invoice: inv-002: finalize endpoint unavailable'
			})
		);
		expect(result).not.toHaveProperty('status');
	});
});
