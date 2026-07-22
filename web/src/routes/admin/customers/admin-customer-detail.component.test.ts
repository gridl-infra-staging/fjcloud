/**
 * Tab-content verification tests for the customer detail page.
 * Extracted from admin-customers.test.ts to stay under the 800-line limit.
 *
 * Tests verify that each tab renders the correct content from fixture data,
 * and that empty/unavailable states show deterministic copy text.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import { formatDate } from '$lib/format';
import type { InvoiceDetailResponse } from '$lib/api/types';
import { DETAIL_FIXTURE, EMPTY_AUDIT_FIXTURE_ROWS } from './admin-customer-detail.test-fixtures';

vi.mock('$app/forms', () => ({
	applyAction: vi.fn(),
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	invalidate: vi.fn()
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/admin/customers') }
}));

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

const EMPTY_DETAIL_FIXTURE = {
	...DETAIL_FIXTURE,
	indexes: [],
	deployments: [],
	usage: null,
	invoices: [],
	rateCard: null,
	quotas: null,
	audit: EMPTY_AUDIT_FIXTURE_ROWS
};

const UNAVAILABLE_DETAIL_FIXTURE = {
	...DETAIL_FIXTURE,
	indexes: null,
	deployments: null,
	usage: null,
	invoices: null,
	rateCard: null,
	quotas: null,
	audit: null
};

async function renderCustomerDetailPage(
	overrides: Record<string, unknown> = {},
	form?: { error?: string; message?: string; invoiceDetail?: InvoiceDetailResponse }
) {
	const CustomerDetailPage = (await import('./[id]/+page.svelte')).default;

	return render(CustomerDetailPage, {
		data: {
			environment: 'test',
			isAuthenticated: true,
			...DETAIL_FIXTURE,
			...overrides
		},
		form
	});
}

async function openTab(name: string) {
	await fireEvent.click(screen.getByRole('button', { name }));
}

function getSectionByHeading(name: string): HTMLElement {
	const heading = screen.getByRole('heading', { name });
	const section = heading.closest('div');
	expect(section).toBeInstanceOf(HTMLElement);
	return section as HTMLElement;
}

function getDefinitionValue(section: HTMLElement, label: string): HTMLElement {
	const labelNode = within(section).getByText(label, { selector: 'dt' });
	const valueNode = labelNode.nextElementSibling;
	expect(valueNode).toBeInstanceOf(HTMLElement);
	return valueNode as HTMLElement;
}

function getMetricValue(section: HTMLElement, label: string): HTMLElement {
	const labelNode = within(section).getByText(label);
	const card = labelNode.closest('div');
	expect(card).toBeInstanceOf(HTMLElement);
	const valueNode = labelNode.nextElementSibling;
	expect(valueNode).toBeInstanceOf(HTMLElement);
	return valueNode as HTMLElement;
}

describe('Customer detail tab content', () => {
	beforeEach(() => {
		process.env.ADMIN_KEY = 'test-admin-key';
	});

	afterEach(() => {
		cleanup();
		delete process.env.ADMIN_KEY;
		vi.clearAllMocks();
	});

	it('indexes tab renders real inventory rows from fixture data', async () => {
		await renderCustomerDetailPage({
			indexes: [
				{ name: 'alpha', region: 'us-east-1', status: 'running', entries: 0, tier: 'active' }
			]
		});

		await openTab('Indexes');

		expect(screen.queryByText('Index data unavailable.')).not.toBeInTheDocument();
		const indexesSection = getSectionByHeading('Indexes');
		const rows = within(indexesSection).getAllByRole('row');
		expect(rows).toHaveLength(2);
		const alphaRow = rows[1];
		expect(within(alphaRow).getByRole('cell', { name: 'alpha' })).toBeInTheDocument();
		expect(within(alphaRow).getByRole('cell', { name: 'us-east-1' })).toBeInTheDocument();
		expect(within(alphaRow).getByRole('cell', { name: 'running' })).toBeInTheDocument();
		expect(within(alphaRow).getByRole('cell', { name: '0' })).toBeInTheDocument();
		expect(within(alphaRow).getByTestId('tier-badge')).toHaveTextContent('active');
	});

	// --- Indexes null sentinel ---

	it('shows "Index data unavailable." when indexes is null', async () => {
		await renderCustomerDetailPage({ indexes: null });

		await openTab('Indexes');

		expect(screen.getByText('Index data unavailable.')).toBeInTheDocument();
		expect(screen.queryByText('No indexes found for this customer.')).not.toBeInTheDocument();
	});

	// --- Info tab content ---

	it('info tab renders customer detail fields from fixture', async () => {
		await renderCustomerDetailPage();

		// Info is the default active tab — no click needed.
		const infoSection = getSectionByHeading('Customer Info');

		expect(getDefinitionValue(infoSection, 'Name')).toHaveTextContent('Beta Labs');
		expect(getDefinitionValue(infoSection, 'Email')).toHaveTextContent('billing@beta.dev');
		expect(getDefinitionValue(infoSection, 'Status')).toHaveTextContent('suspended');
		expect(getDefinitionValue(infoSection, 'Plan')).toHaveTextContent('shared');
		expect(getDefinitionValue(infoSection, 'Created')).toHaveTextContent(
			formatDate(DETAIL_FIXTURE.tenant.created_at)
		);
		expect(getDefinitionValue(infoSection, 'Stripe Customer ID')).toHaveTextContent('cus_123');
	});

	// --- Deployments tab content ---

	it('deployments tab renders fixture deployment row', async () => {
		await renderCustomerDetailPage();

		await openTab('Deployments');

		const deploymentsSection = getSectionByHeading('Deployments');
		const rows = within(deploymentsSection).getAllByRole('row');
		expect(rows).toHaveLength(2);

		const deploymentRow = rows[1];
		expect(within(deploymentRow).getByRole('cell', { name: 'us-east-1' })).toBeInTheDocument();
		expect(within(deploymentRow).getByRole('cell', { name: 'running' })).toBeInTheDocument();
		expect(within(deploymentRow).getByRole('cell', { name: 'healthy' })).toBeInTheDocument();
		expect(
			within(deploymentRow).getByRole('cell', { name: 'https://node1.flapjack.foo' })
		).toBeInTheDocument();
	});

	// --- Usage tab content ---

	it('usage tab renders fixture stat card values', async () => {
		await renderCustomerDetailPage();

		await openTab('Usage');

		const usageSection = getSectionByHeading('Usage');
		expect(getMetricValue(usageSection, 'Searches')).toHaveTextContent('120,000');
		expect(getMetricValue(usageSection, 'Writes')).toHaveTextContent('25,000');
		expect(getMetricValue(usageSection, 'Avg Storage (GB)')).toHaveTextContent('42.50');
		expect(getMetricValue(usageSection, 'Avg Documents')).toHaveTextContent('92,000');
	});

	// --- Quotas form UI ---

	it('quotas tab renders update form with data-testid anchors when quotas data exists', async () => {
		await renderCustomerDetailPage();

		await openTab('Quotas');

		const form = screen.getByTestId('update-quotas-form');
		expect(within(form).getByLabelText('Max Query RPS')).toHaveValue(100);
		expect(within(form).getByLabelText('Max Write RPS')).toHaveValue(50);
		expect(within(form).getByLabelText('Max Storage Bytes')).toHaveValue(10_737_418_240);
		expect(within(form).getByLabelText('Max Indexes')).toHaveValue(10);
		expect(within(form).getByRole('button', { name: 'Update quotas' })).toHaveAttribute(
			'type',
			'submit'
		);
	});

	it('quotas tab shows success feedback from form.message', async () => {
		const CustomerDetailPage = (await import('./[id]/+page.svelte')).default;

		render(CustomerDetailPage, {
			data: { environment: 'test', isAuthenticated: true, ...DETAIL_FIXTURE },
			form: { message: 'Quotas updated' }
		});

		// The form.message feedback renders in the header area (above tabs)
		expect(screen.getByText('Quotas updated')).toBeInTheDocument();
	});

	it('quotas tab shows error feedback from form.error', async () => {
		const CustomerDetailPage = (await import('./[id]/+page.svelte')).default;

		render(CustomerDetailPage, {
			data: { environment: 'test', isAuthenticated: true, ...DETAIL_FIXTURE },
			form: { error: 'At least one quota value is required' }
		});

		expect(screen.getByText('At least one quota value is required')).toBeInTheDocument();
	});

	// --- Deployments terminate UI ---

	it('deployments tab renders terminate button with data-testid', async () => {
		await renderCustomerDetailPage();

		await openTab('Deployments');

		expect(screen.getByTestId('terminate-deployment-button')).toBeInTheDocument();
		expect(screen.getByTestId('terminate-deployment-form')).toBeInTheDocument();
	});

	it('deployments tab shows success feedback for termination via form.message', async () => {
		const CustomerDetailPage = (await import('./[id]/+page.svelte')).default;

		render(CustomerDetailPage, {
			data: { environment: 'test', isAuthenticated: true, ...DETAIL_FIXTURE },
			form: { message: 'Deployment terminated' }
		});

		expect(screen.getByText('Deployment terminated')).toBeInTheDocument();
	});

	it('deployments tab shows error feedback for termination via form.error', async () => {
		const CustomerDetailPage = (await import('./[id]/+page.svelte')).default;

		render(CustomerDetailPage, {
			data: { environment: 'test', isAuthenticated: true, ...DETAIL_FIXTURE },
			form: { error: 'Deployment ID is required' }
		});

		expect(screen.getByText('Deployment ID is required')).toBeInTheDocument();
	});

	it('invoices tab renders view forms for each invoice row', async () => {
		await renderCustomerDetailPage();

		await openTab('Invoices');

		const invoicesSection = getSectionByHeading('Invoices');
		const rows = within(invoicesSection).getAllByRole('row').slice(1);
		expect(rows).toHaveLength(DETAIL_FIXTURE.invoices.length);

		for (const [index, row] of rows.entries()) {
			const button = within(row).getByRole('button', { name: 'View' });
			expect(button).toHaveAttribute('type', 'submit');
			const form = button.closest('form');
			expect(form).toBeInstanceOf(HTMLFormElement);
			expect(form).toHaveAttribute('method', 'POST');
			expect(form).toHaveAttribute('action', '?/viewInvoice');
			const hiddenInvoiceId = form?.querySelector('input[name="invoice_id"]');
			expect(hiddenInvoiceId).toBeInstanceOf(HTMLInputElement);
			expect(hiddenInvoiceId).toHaveAttribute('type', 'hidden');
			expect(hiddenInvoiceId).toHaveValue(DETAIL_FIXTURE.invoices[index].id);
		}
	});

	it('invoices tab keeps active panel and renders selected Stripe invoice drill-in links exactly', async () => {
		const invoiceDetail: InvoiceDetailResponse = {
			id: DETAIL_FIXTURE.invoices[0].id,
			customer_id: DETAIL_FIXTURE.tenant.id,
			period_start: '2026-01-01',
			period_end: '2026-01-31',
			subtotal_cents: 12000,
			total_cents: 13000,
			tax_cents: 1000,
			currency: 'usd',
			status: 'paid',
			minimum_applied: false,
			stripe_invoice_id: 'in_test_123',
			hosted_invoice_url: 'https://invoice.stripe.com/i/acct_x/test_123',
			pdf_url: 'https://invoice.stripe.com/i/acct_x/test_123/pdf',
			line_items: [],
			created_at: '2026-02-01T00:00:00Z',
			finalized_at: '2026-02-01T01:00:00Z',
			paid_at: '2026-02-02T00:00:00Z'
		};

		const view = await renderCustomerDetailPage();
		await openTab('Invoices');
		await view.rerender({
			data: {
				environment: 'test',
				isAuthenticated: true,
				...DETAIL_FIXTURE
			},
			form: { invoiceDetail }
		});

		expect(screen.getByRole('heading', { name: 'Invoices' })).toBeInTheDocument();
		expect(screen.queryByRole('heading', { name: 'Customer Info' })).not.toBeInTheDocument();
		const panel = screen.getByTestId('invoice-drill-in');
		expect(within(panel).getByText('in_test_123')).toBeInTheDocument();
		const hosted = within(panel).getByRole('link', {
			name: 'https://invoice.stripe.com/i/acct_x/test_123'
		});
		expect(hosted).toHaveAttribute('href', 'https://invoice.stripe.com/i/acct_x/test_123');
		expect(hosted).toHaveAttribute('target', '_blank');
		expect(hosted).toHaveAttribute('rel', 'noopener');
		const pdf = within(panel).getByRole('link', {
			name: 'https://invoice.stripe.com/i/acct_x/test_123/pdf'
		});
		expect(pdf).toHaveAttribute('href', 'https://invoice.stripe.com/i/acct_x/test_123/pdf');
		expect(pdf).toHaveAttribute('target', '_blank');
		expect(pdf).toHaveAttribute('rel', 'noopener');
	});

	it('invoices tab renders not-available text instead of links for missing Stripe URLs', async () => {
		const invoiceDetail: InvoiceDetailResponse = {
			id: DETAIL_FIXTURE.invoices[1].id,
			customer_id: DETAIL_FIXTURE.tenant.id,
			period_start: '2026-02-01',
			period_end: '2026-02-28',
			subtotal_cents: 18000,
			total_cents: 18000,
			tax_cents: 0,
			currency: 'usd',
			status: 'open',
			minimum_applied: false,
			stripe_invoice_id: 'in_test_missing_urls',
			hosted_invoice_url: null,
			pdf_url: null,
			line_items: [],
			created_at: '2026-03-01T00:00:00Z',
			finalized_at: null,
			paid_at: null
		};

		await renderCustomerDetailPage({}, { invoiceDetail });

		await openTab('Invoices');

		const panel = screen.getByTestId('invoice-drill-in');
		expect(within(panel).getByText('in_test_missing_urls')).toBeInTheDocument();
		expect(within(panel).getAllByText('Not available')).toHaveLength(2);
		expect(within(panel).queryByRole('link')).not.toBeInTheDocument();
	});

	it('invoices tab renders not-available text instead of links for unsafe Stripe URLs', async () => {
		const invoiceDetail: InvoiceDetailResponse = {
			id: DETAIL_FIXTURE.invoices[1].id,
			customer_id: DETAIL_FIXTURE.tenant.id,
			period_start: '2026-02-01',
			period_end: '2026-02-28',
			subtotal_cents: 18000,
			total_cents: 18000,
			tax_cents: 0,
			currency: 'usd',
			status: 'open',
			minimum_applied: false,
			stripe_invoice_id: 'in_test_unsafe_urls',
			hosted_invoice_url: 'javascript:alert(1)',
			pdf_url: 'http://billing.example.com/invoice.pdf',
			line_items: [],
			created_at: '2026-03-01T00:00:00Z',
			finalized_at: null,
			paid_at: null
		};

		await renderCustomerDetailPage({}, { invoiceDetail });

		await openTab('Invoices');

		const panel = screen.getByTestId('invoice-drill-in');
		expect(within(panel).getByText('in_test_unsafe_urls')).toBeInTheDocument();
		expect(within(panel).getAllByText('Not available')).toHaveLength(2);
		expect(within(panel).queryByRole('link')).not.toBeInTheDocument();
	});

	it('invoices tab preserves loopback PDF links that the canonical billing invoice screen allows', async () => {
		const invoiceDetail: InvoiceDetailResponse = {
			id: DETAIL_FIXTURE.invoices[1].id,
			customer_id: DETAIL_FIXTURE.tenant.id,
			period_start: '2026-02-01',
			period_end: '2026-02-28',
			subtotal_cents: 18000,
			total_cents: 18000,
			tax_cents: 0,
			currency: 'usd',
			status: 'open',
			minimum_applied: false,
			stripe_invoice_id: 'in_test_loopback_pdf',
			hosted_invoice_url: null,
			pdf_url: 'http://localhost:8025/local-invoice/in_local/pdf',
			line_items: [],
			created_at: '2026-03-01T00:00:00Z',
			finalized_at: null,
			paid_at: null
		};

		await renderCustomerDetailPage({}, { invoiceDetail });

		await openTab('Invoices');

		const panel = screen.getByTestId('invoice-drill-in');
		const pdf = within(panel).getByRole('link', {
			name: 'http://localhost:8025/local-invoice/in_local/pdf'
		});
		expect(pdf).toHaveAttribute('href', 'http://localhost:8025/local-invoice/in_local/pdf');
		expect(within(panel).getByText('Not available')).toBeInTheDocument();
	});

	it('audit tab renders populated timeline labels and relative timestamps', async () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-04-01T12:00:00Z'));
		try {
			await renderCustomerDetailPage();

			await openTab('Audit');

			expect(screen.getByText('Customer suspended')).toBeInTheDocument();
			expect(screen.getByText('Quotas updated')).toBeInTheDocument();
			expect(screen.getByText('30m ago')).toBeInTheDocument();
			expect(screen.getByText('2 days ago')).toBeInTheDocument();
		} finally {
			vi.useRealTimers();
		}
	});

	// --- Empty / unavailable state tests ---

	describe('empty and unavailable states', () => {
		it('indexes tab shows empty message when array is empty', async () => {
			await renderCustomerDetailPage(EMPTY_DETAIL_FIXTURE);

			await openTab('Indexes');
			expect(screen.getByText('No indexes found for this customer.')).toBeInTheDocument();
		});

		it('indexes tab shows unavailable when null', async () => {
			await renderCustomerDetailPage(UNAVAILABLE_DETAIL_FIXTURE);

			await openTab('Indexes');
			expect(screen.getByText('Index data unavailable.')).toBeInTheDocument();
		});

		it('deployments tab shows empty message when array is empty', async () => {
			await renderCustomerDetailPage(EMPTY_DETAIL_FIXTURE);

			await openTab('Deployments');
			expect(screen.getByText('No deployments found for this customer.')).toBeInTheDocument();
		});

		it('deployments tab shows unavailable when deployments is null', async () => {
			await renderCustomerDetailPage(UNAVAILABLE_DETAIL_FIXTURE);

			await openTab('Deployments');
			expect(screen.getByText('Deployment data unavailable.')).toBeInTheDocument();
		});

		it('usage tab shows unavailable when null', async () => {
			await renderCustomerDetailPage(EMPTY_DETAIL_FIXTURE);

			await openTab('Usage');
			expect(screen.getByText('Usage data unavailable.')).toBeInTheDocument();
		});

		it('invoices tab shows empty message when array is empty', async () => {
			await renderCustomerDetailPage(EMPTY_DETAIL_FIXTURE);

			await openTab('Invoices');
			expect(screen.getByText('No invoices found for this customer.')).toBeInTheDocument();
		});

		it('invoices tab shows unavailable when invoices is null', async () => {
			await renderCustomerDetailPage(UNAVAILABLE_DETAIL_FIXTURE);

			await openTab('Invoices');
			expect(screen.getByText('Invoice data unavailable.')).toBeInTheDocument();
		});

		it('rate card tab shows unavailable when null', async () => {
			await renderCustomerDetailPage(EMPTY_DETAIL_FIXTURE);

			await openTab('Rate Card');
			expect(screen.getByText('Rate card unavailable.')).toBeInTheDocument();
		});

		it('quotas tab shows unavailable when null', async () => {
			await renderCustomerDetailPage(EMPTY_DETAIL_FIXTURE);

			await openTab('Quotas');
			expect(screen.getByText('Quota data unavailable.')).toBeInTheDocument();
		});

		it('audit tab shows empty message when audit rows are empty', async () => {
			await renderCustomerDetailPage(EMPTY_DETAIL_FIXTURE);

			await openTab('Audit');
			expect(
				screen.getByText('No audit events recorded for this customer yet.')
			).toBeInTheDocument();
		});

		it('audit tab shows unavailable when audit rows are null', async () => {
			await renderCustomerDetailPage(UNAVAILABLE_DETAIL_FIXTURE);

			await openTab('Audit');
			expect(screen.getByText('Audit timeline unavailable.')).toBeInTheDocument();
		});
	});
});
