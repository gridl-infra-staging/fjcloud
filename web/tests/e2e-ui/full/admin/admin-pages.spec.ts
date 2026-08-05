/**
 * Full — Admin Page Shells + Admin Workflows
 *
 * Smoke coverage for admin routes not covered by fleet.spec.ts,
 * plus row-level quick-action control coverage.
 * Each shell test proves the route renders its heading plus the primary
 * table or deterministic empty state.
 *
 * Detail-page suspend/reactivate and impersonation workflows live in
 * customer-detail.spec.ts (the single owner for those flows).
 *
 * Auth: uses .auth/admin.json (loaded via chromium:admin project).
 * Fleet.spec.ts remains the sole owner of nav inventory, login-page,
 * and unauthenticated-redirect coverage.
 */

import { expect, sleep, test } from '../../../fixtures/fixtures';
import type { Locator, Page } from '@playwright/test';
import { navigateToAdminPage, waitForBillingSectionsToResolve } from './admin_page_helpers';

// ---------------------------------------------------------------------------
// Nav-backed pages: Customers, Migrations, Replicas
// ---------------------------------------------------------------------------

test.describe('Admin page shells — nav-backed', () => {
	test('Customers page renders its seeded customer row content', async ({ page, createUser }) => {
		const seed = Date.now();
		const customerName = `Admin Customers Load Verify ${seed}`;
		const customerEmail = `admin-customers-load-${seed}@e2e.griddle.test`;
		await createUser(customerEmail, 'TestPassword123!', customerName);

		const customerRow = await findCustomerRow(page, customerName, 'active');
		await expect(customerRow.getByRole('link', { name: customerName })).toBeVisible();
		await expect(customerRow).toContainText(customerEmail);
		await expect(customerRow.getByTestId('index-count')).toHaveText('0');
		await expect(page.getByText('Customer data unavailable.')).toHaveCount(0);
	});

	test('Migrations page renders heading and active/recent sections', async ({ page }) => {
		await navigateToAdminPage(page, '/admin/migrations', 'Migration Management');

		// Active migrations section: table or empty state
		const activeTable = page.getByTestId('active-migrations-table');
		const activeEmpty = page.getByText('No active migrations.');
		await expect(activeTable.or(activeEmpty)).toBeVisible();

		// Recent migrations section: table or empty state
		const recentTable = page.getByTestId('recent-migrations-table');
		const recentEmpty = page.getByText('No recent migrations.');
		await expect(recentTable.or(recentEmpty)).toBeVisible();
	});

	test('Replicas page renders heading and table or empty state', async ({ page }) => {
		await navigateToAdminPage(page, '/admin/replicas', 'Replica Management');

		const tableBody = page.getByTestId('replicas-table-body');
		const emptyState = page.getByText('No replicas found.');
		await expect(tableBody.or(emptyState)).toBeVisible();
	});
});

// ---------------------------------------------------------------------------
// Remaining pages: Billing, Alerts, Cold Storage
// ---------------------------------------------------------------------------

test.describe('Admin page shells — remaining', () => {
	test('Billing page renders its seeded draft invoice row content', async ({
		page,
		createUser,
		seedAdminDraftInvoice
	}) => {
		const seed = Date.now();
		const customerName = `Admin Billing Draft ${seed}`;
		const customerEmail = `admin-billing-draft-${seed}@e2e.griddle.test`;
		const customer = await createUser(customerEmail, 'TestPassword123!', customerName);
		await seedAdminDraftInvoice(customer, '2025-01');

		await navigateToAdminPage(page, '/admin/billing', 'Billing Review');

		await expect(page.getByTestId('failed-invoices-section')).toBeVisible();
		await expect(page.getByTestId('draft-invoices-section')).toBeVisible();
		const { failedRows, failedEmptyState } = await waitForBillingSectionsToResolve(page);
		await expect(failedRows.or(failedEmptyState)).toBeVisible();

		const draftRow = page
			.getByTestId('draft-invoice-row')
			.filter({ has: page.getByText(customerName, { exact: true }) });
		await expect(draftRow).toHaveCount(1);
		await expect(draftRow.getByTestId('draft-invoice-customer')).toHaveText(customerName);
		await expect(draftRow.getByTestId('draft-invoice-email')).toHaveText(customerEmail);
		await expect(draftRow.getByTestId('draft-invoice-amount')).toHaveText('$0.00');
	});

	test('Alerts page renders heading and table or empty state', async ({ page }) => {
		await navigateToAdminPage(page, '/admin/alerts', 'Alerts');

		const tableBody = page.getByTestId('alerts-table-body');
		const emptyState = page.getByText('No alerts found.');
		await expect(tableBody.or(emptyState)).toBeVisible();
	});

	test('Cold Storage page renders heading and table or empty state', async ({ page }) => {
		// Cold Storage has no sidebar nav item — go directly
		await page.goto('/admin/cold');

		await expect(page.getByRole('heading', { name: 'Cold Storage' })).toBeVisible();

		const tableBody = page.getByTestId('cold-table-body');
		const emptyState = page.getByText('No indexes in cold storage.');
		await expect(tableBody.or(emptyState)).toBeVisible();
	});
});

// ---------------------------------------------------------------------------
// Helper: navigate to customers page, search for a specific seeded customer,
// and return the matching row once it is visible.
// ---------------------------------------------------------------------------

async function findCustomerRow(
	page: Page,
	customerName: string,
	status: 'active' | 'suspended' | 'deleted'
): Promise<import('@playwright/test').Locator> {
	const customerRow = (): Locator =>
		page
			.getByTestId('customers-table-body')
			.getByRole('row')
			.filter({ has: page.getByRole('link', { name: customerName }) });

	await expect(async () => {
		await navigateToAdminPage(page, '/admin/customers', 'Customer Management');
		await page.getByTestId('status-filter').selectOption(status);
		await page.getByTestId('customer-search').fill(customerName);
		await expect(customerRow()).toHaveCount(1, { timeout: 5_000 });
		await expect(customerRow().getByRole('link', { name: customerName })).toBeVisible({
			timeout: 5_000
		});
	}).toPass({
		intervals: [1_000, 2_000, 3_000, 4_000],
		timeout: 20_000
	});

	return customerRow();
}

// ---------------------------------------------------------------------------
// Customer quick actions and status-gated controls
// ---------------------------------------------------------------------------

test.describe('Admin customer actions', () => {
	test('Active customer row shows quick-suspend and quick-impersonate', async ({
		page,
		createUser
	}) => {
		const seed = Date.now();
		const customerName = `Admin Pages Active ${seed}`;
		await createUser(
			`admin-pages-active-${seed}@e2e.griddle.test`,
			'TestPassword123!',
			customerName
		);
		const row = await findCustomerRow(page, customerName, 'active');

		// Active rows must show both quick-suspend and quick-impersonate
		await expect(row.getByTestId('quick-suspend')).toBeVisible();
		await expect(row.getByTestId('quick-impersonate')).toBeVisible();
	});
});

// ---------------------------------------------------------------------------
// Customer list data truthfulness
// ---------------------------------------------------------------------------

test.describe('Admin customer list truthfulness', () => {
	test('Billing-health sort reorders by health before created date', async ({
		page,
		createUser,
		adminDeleteCustomer
	}) => {
		const seed = Date.now();
		const customerPrefix = `Admin Health Sort ${seed}`;
		const olderGreyName = `${customerPrefix} Older Grey`;
		const newerGreenName = `${customerPrefix} Newer Green`;

		const olderGreyCustomer = await createUser(
			`admin-health-sort-grey-${seed}@e2e.griddle.test`,
			'TestPassword123!',
			olderGreyName
		);
		await adminDeleteCustomer(olderGreyCustomer.customerId);
		// Keep the API-created timestamps in distinct database seconds. The wait
		// stays in the fixture/setup owner instead of using a browser sleep.
		await sleep(1_100);
		await createUser(
			`admin-health-sort-green-${seed}@e2e.griddle.test`,
			'TestPassword123!',
			newerGreenName
		);

		await navigateToAdminPage(page, '/admin/customers', 'Customer Management');
		await page.getByTestId('customer-search').fill(customerPrefix);

		const tableBody = page.getByTestId('customers-table-body');
		await expect
			.poll(async () => tableBody.getByRole('row').count(), {
				message: 'expected exactly the two seeded cross-health customers'
			})
			.toBe(2);

		const rows = tableBody.getByRole('row');
		await expect(rows).toHaveCount(2);
		await expect(rows.nth(0).getByRole('link', { name: newerGreenName })).toBeVisible();
		await expect(rows.nth(0).getByTestId(/^billing-health-badge-/)).toHaveText('Green');
		await expect(rows.nth(1).getByRole('link', { name: olderGreyName })).toBeVisible();
		await expect(rows.nth(1).getByTestId(/^billing-health-badge-/)).toHaveText('Grey');

		const sortBillingHealth = page.getByTestId('sort-billing-health');
		await sortBillingHealth.click();
		await expect(sortBillingHealth).toContainText('sorted');

		const sortedRows = tableBody.getByRole('row');
		await expect(sortedRows).toHaveCount(2);
		await expect(sortedRows.nth(0).getByRole('link', { name: olderGreyName })).toBeVisible();
		await expect(sortedRows.nth(0).getByTestId(/^billing-health-badge-/)).toHaveText('Grey');
		await expect(sortedRows.nth(1).getByRole('link', { name: newerGreenName })).toBeVisible();
		await expect(sortedRows.nth(1).getByTestId(/^billing-health-badge-/)).toHaveText('Green');
	});

	test('Customer list exposes billing-health and last-activity columns', async ({
		page,
		createUser
	}) => {
		const seed = Date.now();
		const customerName = `Admin Zero Index ${seed}`;
		await createUser(`admin-zero-index-${seed}@e2e.griddle.test`, 'TestPassword123!', customerName);

		const customerRow = await findCustomerRow(page, customerName, 'active');

		const sortBillingHealth = page.getByTestId('sort-billing-health');
		await expect(sortBillingHealth).toBeVisible();

		await expect(customerRow).toBeVisible();
		await expect(customerRow.getByTestId('index-count')).toHaveText('0');
		// Badge and last-activity cells use per-customer testid suffixes
		// (billing-health-badge-<id>, last-activity-cell-<id>), so scope by
		// data-testid prefix within the row.
		await expect(customerRow.getByTestId(/^billing-health-badge-/)).toHaveText(
			/^(Green|Yellow|Red|Grey)$/
		);
		await expect(customerRow.getByTestId(/^last-activity-cell-/)).toHaveText(
			/^(—|just now|\d+m ago|\d+h ago|\d+ days ago)$/
		);
	});
});
