import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import { getAccessibilityViolations } from '../../../tests/a11y';
import BillingPage from './+page.svelte';

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

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

const invoices = [
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
	}
];

const pageData = {
	summary: {
		status_totals: {
			paid: { total_cents: 12000, count: 1 },
			draft: { total_cents: 25000, count: 1 },
			finalized: { total_cents: 0, count: 0 },
			failed: { total_cents: 8500, count: 1 },
			refunded: { total_cents: 0, count: 0 }
		},
		pending_total_cents: 25000,
		pending_count: 1,
		total_count: 3,
		by_month: [{ month: '2026-03', paid_total_cents: 12000 }],
		mrr_proxy_cents: 42000,
		invoices
	},
	invoices
};

describe('Admin billing page accessibility', () => {
	it('has no structural accessibility violations for populated, dialog, success, and error states', async () => {
		const { container } = render(BillingPage, { data: pageData });
		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);

		await fireEvent.click(document.querySelector('[data-testid="run-billing-button"]')!);
		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);

		cleanup();
		const { container: successContainer } = render(BillingPage, {
			data: pageData,
			form: { message: 'Billing run started' }
		});
		await expect(getAccessibilityViolations(successContainer)).resolves.toEqual([]);

		cleanup();
		const { container: errorContainer } = render(BillingPage, {
			data: pageData,
			form: { error: 'Billing run failed' }
		});
		await expect(getAccessibilityViolations(errorContainer)).resolves.toEqual([]);
	}, 15_000);
});
