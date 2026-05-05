/**
 * Full — Billing
 *
 * Verifies the complete billing surface:
 *   - Load-and-verify: billing page renders the Billing heading
 *   - Billing page renders in-app payment-method UI or the unavailable card
 *   - Invoices page renders (empty or with rows)
 *   - Invoice detail page renders heading, dates, and line items
 *   - Invoice PDF download link renders when backend provides pdf_url
 */

import { test, expect } from '../../fixtures/fixtures';
import { SUPPORT_EMAIL } from '../../../src/lib/format';

test.describe('Billing page', () => {
	test('load-and-verify: billing page renders Billing heading', async ({ page }) => {
		// Act: navigate to billing
		await page.goto('/dashboard/billing');

		// Assert: page-specific heading (not sidebar "Billing" nav link)
		await expect(page.getByRole('heading', { name: 'Billing' })).toBeVisible();
	});

	test('billing page renders app-owned payment-method state or deterministic unavailable state', async ({
		page
	}) => {
		await page.goto('/dashboard/billing');

		const unavailableHeading = page.getByText('Payment method management unavailable');
		if ((await unavailableHeading.count()) > 0) {
			await expect(unavailableHeading).toBeVisible();
			await expect(
				page.getByText(
					'Stripe is not available in this environment. Payment method management is disabled.'
				)
			).toBeVisible();
			await expect(page.getByRole('button', { name: 'Manage billing' })).toHaveCount(0);
			return;
		}

		await expect(page.getByRole('heading', { name: 'Payment methods' })).toBeVisible();
		await expect(page.getByRole('heading', { name: 'Add or update card' })).toBeVisible();
		await expect(
			page.getByText('No payment methods on file yet.').or(page.getByText(/ending in/i))
		).toBeVisible();
		await expect(
			page.getByRole('link', { name: `Contact ${SUPPORT_EMAIL} to cancel` })
		).toHaveAttribute('href', `mailto:${SUPPORT_EMAIL}`);

		await expect(page.getByRole('button', { name: 'Manage billing' })).toHaveCount(0);
		await expect(page.getByText(/Stripe Customer Portal/i)).toHaveCount(0);
		// eslint-disable-next-line playwright/no-raw-locators -- route action attribute contract assertion
		await expect(page.locator('form[action="?/manageBilling"]')).toHaveCount(0);
	});
});

test.describe('Invoices page', () => {
	test('load-and-verify: invoices page renders correctly', async ({ page }) => {
		// Act: navigate to invoices
		await page.goto('/dashboard/billing/invoices');

		// Assert: page-specific heading visible
		await expect(page.getByRole('heading', { name: 'Invoices' })).toBeVisible();

		// Assert: either the table headers or the empty-state message is shown
		const tableHeaders = page.getByRole('columnheader', { name: 'Period' });
		const emptyState = page.getByText('No invoices yet');

		await expect(tableHeaders.or(emptyState)).toBeVisible({ timeout: 5_000 });
	});
});

test.describe('Invoice detail page', () => {
	test('load-and-verify: invoice detail renders heading, dates, line items, and PDF action', async ({
		page,
		seedInvoiceWithPdfUrl
	}) => {
		// Arrange: ensure an invoice with backend-provided pdf_url exists.
		let id: string;
		try {
			({ id } = await seedInvoiceWithPdfUrl());
		} catch (error) {
			if (
				error instanceof Error &&
				error.message.includes('customer has no stripe account linked')
			) {
				// eslint-disable-next-line playwright/no-skipped-test -- PDF proof requires local Stripe account state
				test.skip(
					true,
					'Invoice PDF generation is unavailable without a local Stripe-backed billing account'
				);
			}
			throw error;
		}

		// Act: navigate to invoice detail
		await page.goto(`/dashboard/billing/invoices/${id}`);

		// Assert: back navigation link
		await expect(page.getByRole('link', { name: /back to invoices/i })).toBeVisible();

		// Assert: date labels rendered
		await expect(page.getByText('Created')).toBeVisible();

		// Assert: line items table structure
		await expect(page.getByRole('heading', { name: 'Line Items' })).toBeVisible();
		await expect(page.getByRole('columnheader', { name: 'Description' })).toBeVisible();
		await expect(page.getByRole('columnheader', { name: 'Amount' })).toBeVisible();
		await expect(page.getByRole('columnheader', { name: 'Region' })).toBeVisible();
		const downloadPdfLink = page.getByRole('link', { name: 'Download PDF' });
		await expect(downloadPdfLink).toBeVisible();
		await expect(downloadPdfLink).toHaveAttribute('href', /\/pdf(?:\?|$)/);
	});
});
