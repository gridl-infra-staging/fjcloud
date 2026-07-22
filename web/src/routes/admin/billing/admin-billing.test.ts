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
	tax_cents: number;
	total_cents: number;
	currency: string;
	status: string;
	minimum_applied: boolean;
	stripe_invoice_id: string | null;
	hosted_invoice_url: string | null;
	pdf_url: string | null;
	created_at: string;
	finalized_at: string | null;
	paid_at: string | null;
}

interface BillingStatusTotal {
	total_cents: number;
	count: number;
}

interface BillingSummary {
	status_totals: Record<string, BillingStatusTotal>;
	pending_total_cents: number;
	pending_count: number;
	total_count: number;
	by_month: { month: string; paid_total_cents: number }[];
	mrr_proxy_cents: number;
	invoices: BillingInvoice[];
}

const SUMMARY_INVOICES_FIXTURE: BillingInvoice[] = [
	{
		id: 'inv-0001',
		customer_id: 'cust-0001',
		customer_name: 'Acme Corp',
		customer_email: 'ops@acme.dev',
		period_start: '2026-02-01',
		period_end: '2026-02-28',
		subtotal_cents: 12000,
		tax_cents: 0,
		total_cents: 12000,
		currency: 'usd',
		status: 'paid',
		minimum_applied: false,
		stripe_invoice_id: 'in_paid_1',
		hosted_invoice_url: null,
		pdf_url: null,
		created_at: '2026-03-01T00:00:00Z',
		finalized_at: '2026-03-01T00:00:00Z',
		paid_at: '2026-03-05T00:00:00Z'
	},
	{
		id: 'inv-0002',
		customer_id: 'cust-0002',
		customer_name: 'Beta Labs',
		customer_email: 'billing@beta.dev',
		period_start: '2026-02-01',
		period_end: '2026-02-28',
		subtotal_cents: 8500,
		tax_cents: 0,
		total_cents: 8500,
		currency: 'usd',
		status: 'failed',
		minimum_applied: false,
		stripe_invoice_id: 'in_failed_1',
		hosted_invoice_url: null,
		pdf_url: null,
		created_at: '2026-03-01T00:00:00Z',
		finalized_at: '2026-03-01T00:00:00Z',
		paid_at: null
	},
	{
		id: 'inv-0003',
		customer_id: 'cust-0003',
		customer_name: 'Gamma Inc',
		customer_email: 'team@gamma.dev',
		period_start: '2026-02-01',
		period_end: '2026-02-28',
		subtotal_cents: 25000,
		tax_cents: 0,
		total_cents: 25000,
		currency: 'usd',
		status: 'draft',
		minimum_applied: false,
		stripe_invoice_id: null,
		hosted_invoice_url: null,
		pdf_url: null,
		created_at: '2026-03-01T00:00:00Z',
		finalized_at: null,
		paid_at: null
	},
	{
		id: 'inv-0004',
		customer_id: 'cust-0001',
		customer_name: 'Acme Corp',
		customer_email: 'ops@acme.dev',
		period_start: '2026-02-01',
		period_end: '2026-02-28',
		subtotal_cents: 3200,
		tax_cents: 0,
		total_cents: 3200,
		currency: 'usd',
		status: 'finalized',
		minimum_applied: false,
		stripe_invoice_id: 'in_finalized_1',
		hosted_invoice_url: null,
		pdf_url: null,
		created_at: '2026-03-01T00:00:00Z',
		finalized_at: '2026-03-01T00:00:00Z',
		paid_at: null
	},
	{
		id: 'inv-0005',
		customer_id: 'cust-0004',
		customer_name: 'Delta Co',
		customer_email: 'pay@delta.dev',
		period_start: '2026-03-01',
		period_end: '2026-03-31',
		subtotal_cents: 15000,
		tax_cents: 0,
		total_cents: 15000,
		currency: 'usd',
		status: 'paid',
		minimum_applied: false,
		stripe_invoice_id: 'in_paid_2',
		hosted_invoice_url: null,
		pdf_url: null,
		created_at: '2026-04-01T00:00:00Z',
		finalized_at: '2026-04-01T00:00:00Z',
		paid_at: '2026-04-05T00:00:00Z'
	}
];

const BILLING_SUMMARY_FIXTURE: BillingSummary = {
	status_totals: {
		paid: { total_cents: 27000, count: 2 },
		draft: { total_cents: 25000, count: 1 },
		finalized: { total_cents: 3200, count: 1 },
		failed: { total_cents: 8500, count: 1 },
		refunded: { total_cents: 0, count: 0 }
	},
	pending_total_cents: 28200,
	pending_count: 2,
	total_count: 5,
	by_month: [
		{ month: '2026-02', paid_total_cents: 12000 },
		{ month: '2026-03', paid_total_cents: 15000 }
	],
	mrr_proxy_cents: 42000,
	invoices: SUMMARY_INVOICES_FIXTURE
};

const PAGE_DATA_FIXTURE = {
	summary: BILLING_SUMMARY_FIXTURE,
	invoices: SUMMARY_INVOICES_FIXTURE
};
const BULK_FINALIZE_INVOICE_ID_ONE = '11111111-1111-4111-8111-111111111111';
const BULK_FINALIZE_INVOICE_ID_TWO = '22222222-2222-4222-8222-222222222222';

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
			data: PAGE_DATA_FIXTURE
		});

		expect(screen.getByTestId('total-invoices')).toHaveTextContent('5');
		expect(screen.getByTestId('paid-count')).toHaveTextContent('2');
		expect(screen.getByTestId('failed-count')).toHaveTextContent('1');
		expect(screen.getByTestId('pending-count')).toHaveTextContent('2');
	});

	it('shows exact dollar KPIs from the billing summary', async () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-03-15T12:00:00Z'));

		const BillingPage = (await import('./+page.svelte')).default;

		render(BillingPage, {
			data: PAGE_DATA_FIXTURE
		});

		expect(screen.getByTestId('kpi-total-revenue')).toHaveTextContent('$270.00');
		expect(screen.getByTestId('kpi-mrr')).toHaveTextContent('$420.00');
		expect(screen.getByTestId('kpi-this-month')).toHaveTextContent('$150.00');
	});

	it('renders failed invoices table with customer info and amount', async () => {
		const BillingPage = (await import('./+page.svelte')).default;

		render(BillingPage, {
			data: PAGE_DATA_FIXTURE
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
			data: PAGE_DATA_FIXTURE
		});

		const draftSection = screen.getByTestId('draft-invoices-section');
		const rows = within(draftSection).getAllByRole('row');
		// header + 1 draft invoice
		expect(rows).toHaveLength(2);

		expect(within(draftSection).getByText('Gamma Inc')).toBeInTheDocument();
		expect(within(draftSection).getByText('team@gamma.dev')).toBeInTheDocument();
		expect(within(draftSection).getByText('$250.00')).toBeInTheDocument();

		// Bulk finalize button exists
		expect(screen.getByRole('button', { name: /finalize/i })).toBeInTheDocument();
	});

	it('renders top-page success feedback from form.message', async () => {
		const BillingPage = (await import('./+page.svelte')).default;

		render(BillingPage, {
			data: PAGE_DATA_FIXTURE,
			form: { message: 'Billing complete: 2 invoices created, 1 skipped' }
		});

		expect(screen.getByText('Billing complete: 2 invoices created, 1 skipped')).toBeInTheDocument();
	});

	it('renders top-page error feedback from form.error', async () => {
		const BillingPage = (await import('./+page.svelte')).default;

		render(BillingPage, {
			data: PAGE_DATA_FIXTURE,
			form: { error: 'Bulk finalize failed: inv-001: upstream error' }
		});

		expect(screen.getByText('Bulk finalize failed: inv-001: upstream error')).toBeInTheDocument();
	});

	it('defaults the billing month input to the local calendar month', async () => {
		// Pin a clock that lands on the same calendar month in every reasonable
		// host timezone. The earlier `2026-03-01T00:30:00Z` only sat in February
		// for local timezones west of UTC; UTC-runner CI environments saw March
		// and failed the assertion. Mid-month UTC has no such ambiguity.
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-03-15T12:00:00Z'));

		const BillingPage = (await import('./+page.svelte')).default;

		render(BillingPage, {
			data: PAGE_DATA_FIXTURE
		});

		await fireEvent.click(screen.getByTestId('run-billing-button'));

		expect(screen.getByLabelText('Billing month')).toHaveValue('2026-03');
	});
});

describe('Billing page server load', () => {
	it('loads joined invoice rows from one billing summary request', async () => {
		const { load } = await import('./+page.server');

		const requestedUrls: string[] = [];

		const mockFetch = async (input: string | URL | Request) => {
			const url = typeof input === 'string' ? input : input.toString();
			requestedUrls.push(url);
			if (url.endsWith('/admin/billing/summary')) {
				return new Response(JSON.stringify(BILLING_SUMMARY_FIXTURE), { status: 200 });
			}
			return new Response('Not Found', { status: 404 });
		};

		const result = await load({
			fetch: mockFetch,
			depends: () => {}
		} as never);

		expect(requestedUrls).toHaveLength(1);
		expect(requestedUrls[0]).toMatch(/\/admin\/billing\/summary$/);
		expect(requestedUrls.some((url) => url.includes('/admin/tenants'))).toBe(false);
		expect(result!.summary.status_totals.paid.total_cents).toBe(27000);
		expect(result!.summary.mrr_proxy_cents).toBe(42000);
		expect(result!.invoices).toHaveLength(5);
		expect(result!.invoices.find((i: BillingInvoice) => i.status === 'failed')?.customer_name).toBe(
			'Beta Labs'
		);
		expect(result!.invoices.find((i: BillingInvoice) => i.status === 'draft')?.customer_email).toBe(
			'team@gamma.dev'
		);
	});

	it('returns a complete empty summary fallback on API error', async () => {
		const { load } = await import('./+page.server');

		const mockFetch = async () => new Response('Internal Server Error', { status: 500 });

		const result = await load({
			fetch: mockFetch,
			depends: () => {}
		} as never);

		expect(result!.summary).toEqual({
			status_totals: {
				paid: { total_cents: 0, count: 0 },
				draft: { total_cents: 0, count: 0 },
				finalized: { total_cents: 0, count: 0 },
				failed: { total_cents: 0, count: 0 },
				refunded: { total_cents: 0, count: 0 }
			},
			pending_total_cents: 0,
			pending_count: 0,
			total_count: 0,
			by_month: [],
			mrr_proxy_cents: 0,
			invoices: []
		});
		expect(result!.invoices).toEqual([]);
	});

	it('normalizes malformed billing summary payloads from a 200 response', async () => {
		const { load } = await import('./+page.server');

		const malformedSummary = {
			status_totals: {
				paid: { total_cents: 27000 },
				failed: 'bad-shape'
			},
			pending_total_cents: 'bad-shape',
			pending_count: 2,
			total_count: 3,
			by_month: [{ month: '2026-03', paid_total_cents: 15000 }, { month: 'bad' }],
			mrr_proxy_cents: 42000,
			invoices: [
				{
					id: 'inv-valid',
					customer_id: 'cust-valid',
					customer_name: 'Acme Corp',
					customer_email: 'ops@acme.dev',
					period_start: '2026-03-01',
					period_end: '2026-03-31',
					status: 'paid',
					created_at: '2026-04-01T00:00:00Z'
				},
				{
					id: 'inv-invalid',
					customer_id: 'cust-invalid',
					status: 'draft',
					created_at: '2026-04-01T00:00:00Z'
				}
			]
		};

		const result = await load({
			fetch: async () => new Response(JSON.stringify(malformedSummary), { status: 200 }),
			depends: () => {}
		} as never);

		expect(result!.summary.status_totals.paid).toEqual({ total_cents: 27000, count: 0 });
		expect(result!.summary.status_totals.failed).toEqual({ total_cents: 0, count: 0 });
		expect(result!.summary.pending_total_cents).toBe(0);
		expect(result!.summary.pending_count).toBe(2);
		expect(result!.summary.total_count).toBe(3);
		expect(result!.summary.by_month).toEqual([{ month: '2026-03', paid_total_cents: 15000 }]);
		expect(result!.summary.invoices).toHaveLength(1);
		expect(result!.summary.invoices[0]).toMatchObject({
			id: 'inv-valid',
			customer_name: 'Acme Corp',
			total_cents: 0,
			currency: ''
		});
		expect(result!.invoices).toEqual(result!.summary.invoices);
	});

	it('returns summary invoices in deterministic route-owned order', async () => {
		const { load } = await import('./+page.server');

		const outOfOrderSummary: BillingSummary = {
			...BILLING_SUMMARY_FIXTURE,
			invoices: [
				{
					...SUMMARY_INVOICES_FIXTURE[2],
					id: 'inv-100',
					customer_name: 'Acme Corp',
					created_at: '2026-03-02T09:00:00Z'
				},
				{
					...SUMMARY_INVOICES_FIXTURE[1],
					id: 'inv-090',
					customer_id: 'cust-0001',
					customer_name: 'Acme Corp',
					customer_email: 'ops@acme.dev',
					created_at: '2026-03-02T09:00:00Z'
				},
				{
					...SUMMARY_INVOICES_FIXTURE[0],
					id: 'inv-200',
					customer_name: 'Beta Labs',
					created_at: '2026-03-02T09:00:00Z'
				},
				{
					...SUMMARY_INVOICES_FIXTURE[4],
					id: 'inv-300',
					customer_name: 'Gamma Inc',
					created_at: '2026-03-03T12:00:00Z'
				}
			]
		};

		const result = await load({
			fetch: async () => new Response(JSON.stringify(outOfOrderSummary), { status: 200 }),
			depends: () => {}
		} as never);

		expect(
			result!.invoices.map((invoice: BillingInvoice) => `${invoice.id}:${invoice.customer_name}`)
		).toEqual(['inv-300:Gamma Inc', 'inv-090:Acme Corp', 'inv-100:Acme Corp', 'inv-200:Beta Labs']);
		expect(result!.invoices[1].customer_email).toBe('ops@acme.dev');
	});
});

describe('Admin client billing methods', () => {
	it('getBillingSummary calls GET /admin/billing/summary', async () => {
		let capturedUrl = '';
		let capturedMethod = '';

		const { AdminClient } = await import('$lib/admin-client');
		const client = new AdminClient('http://localhost:3000', 'test-key');
		client.setFetch(async (input: string | URL | Request, init?: RequestInit) => {
			capturedUrl = typeof input === 'string' ? input : input.toString();
			capturedMethod = init?.method ?? 'GET';
			return new Response(JSON.stringify(BILLING_SUMMARY_FIXTURE), { status: 200 });
		});

		const result = await client.getBillingSummary();

		expect(capturedUrl).toBe('http://localhost:3000/admin/billing/summary');
		expect(capturedMethod).toBe('GET');
		expect(result.status_totals.paid.total_cents).toBe(27000);
	});

	it('runBatchBilling calls POST /admin/billing/run with month', async () => {
		let capturedUrl = '';
		let capturedMethod = '';
		let capturedBody = '';

		const { AdminClient } = await import('$lib/admin-client');
		const client = new AdminClient('http://localhost:3000', 'test-key');
		client.setFetch(async (input: string | URL | Request, init?: RequestInit) => {
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

	it('finalizeInvoice percent-encodes the invoice ID path segment', async () => {
		let capturedUrl = '';

		const { AdminClient } = await import('$lib/admin-client');
		const client = new AdminClient('http://localhost:3000', 'test-key');
		client.setFetch(async (input: string | URL | Request) => {
			capturedUrl = typeof input === 'string' ? input : input.toString();
			return new Response(JSON.stringify({ id: 'ignored', status: 'finalized' }), { status: 200 });
		});

		await client.finalizeInvoice('../customers/target');

		expect(capturedUrl).toBe(
			'http://localhost:3000/admin/invoices/..%2Fcustomers%2Ftarget/finalize'
		);
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
		formData.append('invoice_ids', BULK_FINALIZE_INVOICE_ID_ONE);
		formData.append('invoice_ids', BULK_FINALIZE_INVOICE_ID_TWO);

		const result = await actions.bulkFinalize({
			request: new Request('http://localhost/admin/billing?/bulkFinalize', {
				method: 'POST',
				body: formData
			}),
			fetch: async (input: string | URL | Request) => {
				capturedUrls.push(typeof input === 'string' ? input : input.toString());
				return new Response(JSON.stringify({ id: 'inv-001', status: 'finalized' }), {
					status: 200
				});
			}
		} as never);

		expect(capturedUrls).toHaveLength(2);
		expect(capturedUrls[0]).toContain(
			`/admin/invoices/${BULK_FINALIZE_INVOICE_ID_ONE}/finalize`
		);
		expect(capturedUrls[1]).toContain(
			`/admin/invoices/${BULK_FINALIZE_INVOICE_ID_TWO}/finalize`
		);
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

		expect(result).toEqual(expect.objectContaining({ status: 400 }));
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
		formData.append('invoice_ids', BULK_FINALIZE_INVOICE_ID_ONE);
		formData.append('invoice_ids', BULK_FINALIZE_INVOICE_ID_TWO);

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
					error:
						`Bulk finalize failed: ${BULK_FINALIZE_INVOICE_ID_ONE}: finalize endpoint unavailable; ${BULK_FINALIZE_INVOICE_ID_TWO}: finalize endpoint unavailable`
				})
			})
		);
	});

	it('bulkFinalize action keeps partial-success errors renderable without failing the action', async () => {
		const { actions } = await import('./+page.server');

		const formData = new FormData();
		formData.append('invoice_ids', BULK_FINALIZE_INVOICE_ID_ONE);
		formData.append('invoice_ids', BULK_FINALIZE_INVOICE_ID_TWO);

		const result = await actions.bulkFinalize({
			request: new Request('http://localhost/admin/billing?/bulkFinalize', {
				method: 'POST',
				body: formData
			}),
			fetch: async (input: string | URL | Request) => {
				const url = typeof input === 'string' ? input : input.toString();
				if (url.includes(`/admin/invoices/${BULK_FINALIZE_INVOICE_ID_ONE}/finalize`)) {
					return new Response(
						JSON.stringify({ id: BULK_FINALIZE_INVOICE_ID_ONE, status: 'finalized' }),
						{
							status: 200
						}
					);
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
				error:
					`Bulk finalize partially failed after finalizing 1 invoice: ${BULK_FINALIZE_INVOICE_ID_TWO}: finalize endpoint unavailable`
			})
		);
		expect(result).not.toHaveProperty('status');
	});

	it('bulkFinalize rejects malformed invoice IDs before calling the admin API', async () => {
		const { actions } = await import('./+page.server');

		const formData = new FormData();
		formData.append('invoice_ids', '../customers/target');

		const fetchSpy = vi.fn(async () => new Response('', { status: 200 }));
		const result = await actions.bulkFinalize({
			request: new Request('http://localhost/admin/billing?/bulkFinalize', {
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
					error: 'Invoice IDs must be valid UUIDs'
				})
			})
		);
	});
});
