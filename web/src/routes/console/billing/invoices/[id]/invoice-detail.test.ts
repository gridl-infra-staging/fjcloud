import { describe, it, expect, afterEach } from 'vitest';
import { render, cleanup } from '@testing-library/svelte';
import type { InvoiceDetailResponse } from '$lib/api/types';
import { getAccessibilityViolations } from '../../../../../tests/a11y';
import { layoutTestDefaults } from '../../../layout-test-context';
import InvoiceDetailPage from './+page.svelte';

afterEach(cleanup);

const accessibleInvoice: InvoiceDetailResponse = {
	id: 'inv-1',
	customer_id: 'cust-1',
	period_start: '2026-02-01',
	period_end: '2026-02-28',
	subtotal_cents: 2500,
	total_cents: 2640,
	tax_cents: 140,
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
			description: 'Tax',
			quantity: '1',
			unit: 'invoice',
			unit_price_cents: '140',
			amount_cents: 140,
			region: 'us-east-1'
		}
	],
	created_at: '2026-02-15T00:00:00Z',
	finalized_at: '2026-02-20T00:00:00Z',
	paid_at: null
};

describe('Invoice detail page accessibility', () => {
	it('has no structural accessibility violations for a populated invoice detail', async () => {
		const { container } = render(InvoiceDetailPage, {
			data: { ...layoutTestDefaults, user: null, invoice: accessibleInvoice }
		});

		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);
	});
});
