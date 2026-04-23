import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';
import type { InvoiceListItem, InvoiceDetailResponse } from '$lib/api/types';
import { formatCents, formatDate, formatPeriod, formatUnitPrice, statusLabel } from '$lib/format';
import { layoutTestDefaults } from '../../layout-test-context';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	goto: vi.fn(),
	invalidateAll: vi.fn()
}));

afterEach(cleanup);

const sampleInvoices: InvoiceListItem[] = [
	{
		id: 'inv-1',
		period_start: '2026-02-01',
		period_end: '2026-02-28',
		subtotal_cents: 4500,
		total_cents: 4500,
		status: 'paid',
		minimum_applied: false,
		created_at: '2026-02-15T00:00:00Z'
	},
	{
		id: 'inv-2',
		period_start: '2026-01-01',
		period_end: '2026-01-31',
		subtotal_cents: 3200,
		total_cents: 3200,
		status: 'draft',
		minimum_applied: false,
		created_at: '2026-01-15T00:00:00Z'
	},
	{
		id: 'inv-3',
		period_start: '2025-12-01',
		period_end: '2025-12-31',
		subtotal_cents: 0,
		total_cents: 1000,
		status: 'finalized',
		minimum_applied: true,
		created_at: '2025-12-15T00:00:00Z'
	},
	{
		id: 'inv-4',
		period_start: '2025-11-01',
		period_end: '2025-11-30',
		subtotal_cents: 6000,
		total_cents: 6000,
		status: 'failed',
		minimum_applied: false,
		created_at: '2025-11-15T00:00:00Z'
	},
	{
		id: 'inv-5',
		period_start: '2025-10-01',
		period_end: '2025-10-31',
		subtotal_cents: 7500,
		total_cents: 7500,
		status: 'refunded',
		minimum_applied: false,
		created_at: '2025-10-15T00:00:00Z'
	}
];

// Realistic fixture: unit_price_cents values match billing library output
// (rate * multiplier * 100 — e.g., storage_rate_per_mb=0.05 → 5 cents per MB)
const sampleInvoiceDetail: InvoiceDetailResponse = {
	id: 'inv-1',
	customer_id: 'cust-1',
	period_start: '2026-02-01',
	period_end: '2026-02-28',
	subtotal_cents: 2640,
	total_cents: 2640,
	tax_cents: 0,
	currency: 'usd',
	status: 'finalized',
	minimum_applied: false,
	stripe_invoice_id: 'in_stripe_123',
	hosted_invoice_url: 'https://invoice.stripe.com/pay/abc123',
	pdf_url: 'https://pay.stripe.com/invoice/acct_123/inv_456/pdf',
	line_items: [
		{
			id: 'li-1',
			description: 'Search requests (us-east-1)',
			quantity: '50',
			unit: 'requests_1k',
			unit_price_cents: '50',
			amount_cents: 2500,
			region: 'us-east-1'
		},
		{
			id: 'li-2',
			description: 'Write operations (us-east-1)',
			quantity: '10',
			unit: 'write_ops_1k',
			unit_price_cents: '10',
			amount_cents: 100,
			region: 'us-east-1'
		},
		{
			id: 'li-3',
			description: 'Storage (eu-west-1)',
			quantity: '2.00',
			unit: 'gb_months',
			unit_price_cents: '20',
			amount_cents: 40,
			region: 'eu-west-1'
		}
	],
	created_at: '2026-02-15T00:00:00Z',
	finalized_at: '2026-02-20T00:00:00Z',
	paid_at: null
};

describe('Invoice list page', () => {
	it('renders invoice rows with period, status, total, and row-scoped view links', async () => {
		const { default: InvoiceListPage } = await import('./+page.svelte');
		render(InvoiceListPage, {
			data: { ...layoutTestDefaults, user: null, invoices: sampleInvoices }
		});

		expect(screen.getByRole('heading', { level: 1, name: 'Invoices' })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: 'Period' })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: 'Status' })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: 'Total' })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: 'Actions' })).toBeInTheDocument();

		const invoiceRows = screen.getAllByRole('row').slice(1);
		expect(invoiceRows).toHaveLength(sampleInvoices.length);

		const expectedRows = [
			...sampleInvoices.map((invoice) => ({
				period: formatPeriod(invoice.period_start),
				status: statusLabel(invoice.status),
				total: formatCents(invoice.total_cents),
				href: `/dashboard/billing/invoices/${invoice.id}`
			}))
		];

		expectedRows.forEach((expectedRow, index) => {
			const row = within(invoiceRows[index]);
			expect(row.getByText(expectedRow.period)).toBeInTheDocument();
			expect(row.getByText(expectedRow.status)).toBeInTheDocument();
			expect(row.getByText(expectedRow.total)).toBeInTheDocument();
			expect(row.getByRole('link', { name: 'View' })).toHaveAttribute('href', expectedRow.href);
		});
	});

	it('shows empty state when no invoices', async () => {
		const { default: InvoiceListPage } = await import('./+page.svelte');
		render(InvoiceListPage, { data: { ...layoutTestDefaults, user: null, invoices: [] } });
		expect(screen.getByRole('heading', { level: 1, name: 'Invoices' })).toBeInTheDocument();
		expect(screen.getByText(/no invoices yet/i)).toBeInTheDocument();
		expect(screen.queryByRole('table')).not.toBeInTheDocument();
	});
});

describe('Invoice detail page', () => {
	it('renders invoice detail header, dates, and line items with exact values', async () => {
		const { default: InvoiceDetailPage } = await import('./[id]/+page.svelte');
		render(InvoiceDetailPage, {
			data: { ...layoutTestDefaults, user: null, invoice: sampleInvoiceDetail }
		});

		expect(screen.getByRole('link', { name: /back to invoices/i })).toHaveAttribute(
			'href',
			'/dashboard/billing/invoices'
		);
		expect(
			screen.getByRole('heading', {
				level: 1,
				name: formatPeriod(sampleInvoiceDetail.period_start)
			})
		).toBeInTheDocument();
		expect(screen.getAllByText(statusLabel(sampleInvoiceDetail.status))).toHaveLength(2);
		const createdLabel = screen.getByText('Created');
		const dateGrid = createdLabel.closest('div')?.parentElement;
		const createdSection = createdLabel.closest('div');
		expect(dateGrid).not.toBeNull();
		const finalizedSection = within(dateGrid as HTMLElement).getByText('Finalized').closest('div');
		const paidSection = within(dateGrid as HTMLElement).getByText('Paid').closest('div');
		expect(createdSection).not.toBeNull();
		expect(finalizedSection).not.toBeNull();
		expect(paidSection).not.toBeNull();
		expect(
			within(createdSection as HTMLElement).getByText(formatDate(sampleInvoiceDetail.created_at))
		).toBeInTheDocument();
		expect(
			within(finalizedSection as HTMLElement).getByText(formatDate(sampleInvoiceDetail.finalized_at))
		).toBeInTheDocument();
		expect(
			within(paidSection as HTMLElement).getByText(formatDate(sampleInvoiceDetail.paid_at))
		).toBeInTheDocument();
		expect(screen.queryByText(/^Subtotal:/)).not.toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: 'Description' })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: 'Quantity' })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: 'Unit Price' })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: 'Amount' })).toBeInTheDocument();
		expect(screen.getByRole('columnheader', { name: 'Region' })).toBeInTheDocument();

		const rows = screen.getAllByRole('row').slice(1);
		expect(rows).toHaveLength(sampleInvoiceDetail.line_items.length);

		sampleInvoiceDetail.line_items.forEach((item, index) => {
			const row = within(rows[index]);
			expect(row.getByText(item.description)).toBeInTheDocument();
			expect(row.getByText(`${item.quantity} ${item.unit}`)).toBeInTheDocument();
			expect(row.getByText(formatUnitPrice(item.unit_price_cents))).toBeInTheDocument();
			expect(row.getByText(formatCents(item.amount_cents))).toBeInTheDocument();
			expect(row.getByText(item.region)).toBeInTheDocument();
		});

		expect(screen.getByText(formatCents(sampleInvoiceDetail.total_cents))).toBeInTheDocument();
	});

	it('renders subtotal only when subtotal differs from total', async () => {
		const { default: InvoiceDetailPage } = await import('./[id]/+page.svelte');
		const invoiceWithSubtotal: InvoiceDetailResponse = {
			...sampleInvoiceDetail,
			subtotal_cents: 2500,
			total_cents: 2640
		};
		render(InvoiceDetailPage, {
			data: { ...layoutTestDefaults, user: null, invoice: invoiceWithSubtotal }
		});

		expect(
			screen.getByText(`Subtotal: ${formatCents(invoiceWithSubtotal.subtotal_cents)}`)
		).toBeInTheDocument();
	});

	it.each([
		{
			name: 'shows both pay and PDF links when finalized invoice has both safe links',
			invoice: sampleInvoiceDetail,
			expectPay: true,
			expectPdf: true
		},
		{
			name: 'shows pay link only when finalized invoice has pay URL but no PDF URL',
			invoice: { ...sampleInvoiceDetail, pdf_url: null },
			expectPay: true,
			expectPdf: false
		},
		{
			name: 'shows PDF link only when finalized invoice has PDF URL but no pay URL',
			invoice: { ...sampleInvoiceDetail, hosted_invoice_url: null },
			expectPay: false,
			expectPdf: true
		},
		{
			name: 'shows PDF link only when invoice is paid and pay URL is present',
			invoice: {
				...sampleInvoiceDetail,
				status: 'paid',
				paid_at: '2026-02-21T00:00:00Z'
			},
			expectPay: false,
			expectPdf: true
		},
		{
			name: 'hides both links when invoice is not finalized and has no PDF URL',
			invoice: {
				...sampleInvoiceDetail,
				status: 'draft',
				finalized_at: null,
				pdf_url: null
			},
			expectPay: false,
			expectPdf: false
		}
	])('$name', async ({ invoice, expectPay, expectPdf }) => {
		const { default: InvoiceDetailPage } = await import('./[id]/+page.svelte');
		render(InvoiceDetailPage, {
			data: { ...layoutTestDefaults, user: null, invoice }
		});

		const payLink = screen.queryByRole('link', { name: /pay on stripe/i });
		const pdfLink = screen.queryByRole('link', { name: /download pdf/i });
		if (expectPay) {
			expect(payLink).toBeInTheDocument();
			expect(payLink).toHaveAttribute('href', invoice.hosted_invoice_url as string);
		} else {
			expect(payLink).not.toBeInTheDocument();
		}
		if (expectPdf) {
			expect(pdfLink).toBeInTheDocument();
			expect(pdfLink).toHaveAttribute('href', invoice.pdf_url as string);
		} else {
			expect(pdfLink).not.toBeInTheDocument();
		}
	});

	it('shows PDF download link for loopback LocalStripe pdf_url', async () => {
		const { default: InvoiceDetailPage } = await import('./[id]/+page.svelte');
		const localStripeInvoice: InvoiceDetailResponse = {
			...sampleInvoiceDetail,
			hosted_invoice_url: 'http://localhost:8025/local-invoice/in_local',
			pdf_url: 'http://localhost:8025/local-invoice/in_local/pdf'
		};
		render(InvoiceDetailPage, {
			data: { ...layoutTestDefaults, user: null, invoice: localStripeInvoice }
		});

		const pdfLink = screen.getByRole('link', { name: /download pdf/i });
		expect(pdfLink).toHaveAttribute('href', 'http://localhost:8025/local-invoice/in_local/pdf');
		expect(screen.queryByRole('link', { name: /pay on stripe/i })).not.toBeInTheDocument();
	});

	it('hides PDF download link when pdf_url is null', async () => {
		const { default: InvoiceDetailPage } = await import('./[id]/+page.svelte');
		const invoiceNoPdf: InvoiceDetailResponse = {
			...sampleInvoiceDetail,
			pdf_url: null
		};
		render(InvoiceDetailPage, {
			data: { ...layoutTestDefaults, user: null, invoice: invoiceNoPdf }
		});

		expect(screen.queryByRole('link', { name: /download pdf/i })).not.toBeInTheDocument();
	});

	it('does not render external invoice links for unsafe URL schemes', async () => {
		const { default: InvoiceDetailPage } = await import('./[id]/+page.svelte');
		const invoiceWithUnsafeLinks: InvoiceDetailResponse = {
			...sampleInvoiceDetail,
			hosted_invoice_url: 'javascript:alert(1)',
			pdf_url: 'data:text/html,<script>alert(1)</script>'
		};
		render(InvoiceDetailPage, {
			data: { ...layoutTestDefaults, user: null, invoice: invoiceWithUnsafeLinks }
		});

		expect(screen.queryByRole('link', { name: /pay on stripe/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('link', { name: /download pdf/i })).not.toBeInTheDocument();
	});

	it('does not render remote http PDF links', async () => {
		const { default: InvoiceDetailPage } = await import('./[id]/+page.svelte');
		const invoiceWithRemoteHttpPdf: InvoiceDetailResponse = {
			...sampleInvoiceDetail,
			pdf_url: 'http://billing.example.com/invoice.pdf'
		};
		render(InvoiceDetailPage, {
			data: { ...layoutTestDefaults, user: null, invoice: invoiceWithRemoteHttpPdf }
		});

		expect(screen.queryByRole('link', { name: /download pdf/i })).not.toBeInTheDocument();
	});
});
