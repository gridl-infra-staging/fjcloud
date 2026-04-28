/**
 * Full — Billing
 *
 * Verifies the complete billing surface:
 *   - Load-and-verify: billing page renders the Billing heading
 *   - Billing page exposes a single Stripe portal handoff path or the unavailable card
 *   - Invoices page renders (empty or with rows)
 *   - Invoice detail page renders heading, dates, and line items
 *   - Invoice PDF download link renders when backend provides pdf_url
 */

import type { Page } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';
import { AUTH_COOKIE } from '../../../src/lib/server/auth-session-contracts';

const BASE_URL = process.env.BASE_URL ?? 'http://localhost:5173';

async function setAuthCookieForToken(page: Page, token: string): Promise<void> {
	await page.context().addCookies([
		{
			name: AUTH_COOKIE,
			value: token,
			url: BASE_URL,
			httpOnly: true,
			sameSite: 'Lax'
		}
	]);
}

test.describe('Billing page', () => {
	test('load-and-verify: billing page renders Billing heading', async ({ page }) => {
		// Act: navigate to billing
		await page.goto('/dashboard/billing');

		// Assert: page-specific heading (not sidebar "Billing" nav link)
		await expect(page.getByRole('heading', { name: 'Billing' })).toBeVisible();
	});

	test('billing page exposes manage-billing handoff or deterministic unavailable state', async ({
		page
	}) => {
		await page.goto('/dashboard/billing');

		const manageBillingButton = page.getByRole('button', { name: 'Manage billing' });
		if ((await manageBillingButton.count()) > 0) {
			await expect(manageBillingButton).toBeVisible();
			// eslint-disable-next-line playwright/no-raw-locators -- form lookup by action attr; no role-based or text-based locator equivalent for SvelteKit form actions
			await expect(page.locator('form[action="?/manageBilling"]')).toBeVisible();
			await expect(page.getByRole('link', { name: 'Add payment method' })).toHaveCount(0);
			return;
		}

		await expect(page.getByText('Payment method management unavailable')).toBeVisible();
		await expect(
			page.getByText(
				'Stripe is not available in this environment. Payment method management is disabled.'
			)
		).toBeVisible();
		await expect(manageBillingButton).toHaveCount(0);
	});

	test('billing page shows cancel-at-period-end banner from server-owned subscription state', async ({
		page,
		arrangeBillingPortalCustomer
	}) => {
		let arrangedCustomer: Awaited<ReturnType<typeof arrangeBillingPortalCustomer>>;
		try {
			arrangedCustomer = await arrangeBillingPortalCustomer(true);
		} catch (error) {
			if (error instanceof Error) {
				// eslint-disable-next-line playwright/no-skipped-test -- live Stripe/billing preconditions vary by local environment
				test.skip(true, `Billing cancellation arrange unavailable: ${error.message}`);
			}
			throw error;
		}

		await setAuthCookieForToken(page, arrangedCustomer.token);
		await page.goto('/dashboard/billing');
		await expect(page.getByTestId('subscription-cancelled-banner')).toHaveText(
			`Subscription cancelled, ends ${arrangedCustomer.subscription.current_period_end}`
		);
		await expect(page.getByRole('button', { name: 'Manage billing' })).toBeVisible();
		await expect(page.getByRole('button', { name: /cancel subscription/i })).toHaveCount(0);
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
