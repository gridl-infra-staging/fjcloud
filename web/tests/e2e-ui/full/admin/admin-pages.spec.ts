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

import { expect, test } from '../../../fixtures/fixtures';
import type { Locator, Page } from '@playwright/test';

// ---------------------------------------------------------------------------
// Helper: navigate to an admin page via sidebar link or direct goto.
// Sidebar clicks are route-entry steps, not nav inventory assertions.
// ---------------------------------------------------------------------------

async function navigateToAdminPage(page: Page, path: string, heading: string): Promise<void> {
	await page.goto(path);
	await expect(page.getByRole('heading', { name: heading })).toBeVisible();
}

async function waitForBillingSectionsToResolve(page: Page): Promise<{
	failedRows: Locator;
	draftRows: Locator;
	failedEmptyState: Locator;
	draftEmptyState: Locator;
}> {
	const failedSection = page.getByTestId('failed-invoices-section');
	const draftSection = page.getByTestId('draft-invoices-section');
	const failedRows = page.getByTestId('failed-invoice-row');
	const draftRows = page.getByTestId('draft-invoice-row');
	const failedEmptyState = failedSection.getByText('No failed invoices.');
	const draftEmptyState = draftSection.getByText('No draft invoices awaiting finalization.');

	// Wait for each billing section to resolve before treating missing rows as a seeded-data blocker.
	await expect
		.poll(async () => (await failedRows.count()) + (await failedEmptyState.count()), {
			message: 'failed invoice section should render either seeded rows or its empty state'
		})
		.toBeGreaterThan(0);
	await expect
		.poll(async () => (await draftRows.count()) + (await draftEmptyState.count()), {
			message: 'draft invoice section should render either seeded rows or its empty state'
		})
		.toBeGreaterThan(0);

	return { failedRows, draftRows, failedEmptyState, draftEmptyState };
}

// ---------------------------------------------------------------------------
// Nav-backed pages: Customers, Migrations, Replicas
// ---------------------------------------------------------------------------

test.describe('Admin page shells — nav-backed', () => {
	test('Customers page renders heading and table or empty state', async ({ page }) => {
		await navigateToAdminPage(page, '/admin/customers', 'Customer Management');

		const tableBody = page.getByTestId('customers-table-body');
		const emptyState = page.getByText('No customers found.');
		const unavailableState = page.getByText('Customer data unavailable.');
		await expect(tableBody.or(emptyState)).toBeVisible();
		await expect(unavailableState).toHaveCount(0);
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
	test('Billing page renders seeded failed and draft invoice row content', async ({ page }) => {
		await navigateToAdminPage(page, '/admin/billing', 'Billing Review');

		await expect(page.getByTestId('failed-invoices-section')).toBeVisible();
		await expect(page.getByTestId('draft-invoices-section')).toBeVisible();
		const { failedRows, draftRows, failedEmptyState, draftEmptyState } =
			await waitForBillingSectionsToResolve(page);

		if (await failedRows.count()) {
			const failedRow = failedRows.first();
			await expect(failedRow.getByTestId('failed-invoice-customer')).toHaveText(/\S+/);
			await expect(failedRow.getByTestId('failed-invoice-email')).toHaveText(/@/);
			await expect(failedRow.getByTestId('failed-invoice-amount')).toHaveText(/^\$\d/);
		} else {
			await expect(failedEmptyState).toBeVisible();
		}

		if (await draftRows.count()) {
			const draftRow = draftRows.first();
			await expect(draftRow.getByTestId('draft-invoice-customer')).toHaveText(/\S+/);
			await expect(draftRow.getByTestId('draft-invoice-email')).toHaveText(/@/);
			await expect(draftRow.getByTestId('draft-invoice-amount')).toHaveText(/^\$\d/);
		} else {
			await expect(draftEmptyState).toBeVisible();
		}
	});

	test('Billing Run Billing flow renders visible confirmation text', async ({ page }) => {
		await navigateToAdminPage(page, '/admin/billing', 'Billing Review');

		await page.getByTestId('run-billing-button').click();
		await expect(page.getByTestId('confirm-billing-button')).toBeVisible();
		await page.getByLabel('Billing month').fill('2026-02');
		await page.getByTestId('confirm-billing-button').click();
		await expect(page.getByTestId('billing-feedback-message')).toContainText('Billing complete');
	});

	test('Billing Bulk Finalize flow renders visible confirmation text', async ({ page }) => {
		await navigateToAdminPage(page, '/admin/billing', 'Billing Review');
		const { draftRows, draftEmptyState } = await waitForBillingSectionsToResolve(page);

		if (await draftRows.count()) {
			await page.getByTestId('bulk-finalize-button').click();
			await expect(page.getByTestId('billing-feedback-message')).toContainText(
				'Bulk finalize complete'
			);
		} else {
			await expect(page.getByTestId('bulk-finalize-button')).toHaveCount(0);
			await expect(draftEmptyState).toBeVisible();
		}
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
			.filter({ has: page.getByRole('link', { name: customerName }) })
			.first();

	await expect(async () => {
		await navigateToAdminPage(page, '/admin/customers', 'Customer Management');
		await page.getByTestId('status-filter').selectOption(status);
		await page.getByTestId('customer-search').fill(customerName);
		await expect(customerRow().getByRole('link', { name: customerName })).toBeVisible({
			timeout: 10_000
		});
	}).toPass({
		intervals: [1_000, 2_000, 3_000, 4_000],
		timeout: 30_000
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
	const BILLING_HEALTH_LABEL_RANK: Record<string, number> = {
		Red: 0,
		Yellow: 1,
		Grey: 2,
		Green: 3
	};

	test('Billing-health sort ties are ordered by newest customer first', async ({
		page,
		createUser
	}) => {
		const seed = Date.now();
		const customerPrefix = `Admin Sort Tie ${seed}`;
		const olderName = `${customerPrefix} Older`;
		const newerName = `${customerPrefix} Newer`;

		await createUser(`admin-sort-tie-older-${seed}@e2e.griddle.test`, 'TestPassword123!', olderName);
		// Ensure distinct created_at values for deterministic createdAtMs tie-break
		// ordering. The createUser helper hits the API which writes created_at via
		// PostgreSQL now() with second-resolution truncation in some code paths,
		// so back-to-back creates can land on the same second and produce
		// nondeterministic sort order in the next assertion. Using a real wall-
		// clock delay between creates is the simplest setup-phase shortcut. This
		// lives in arrange (not act/assert), so it's permitted under the
		// browser-testing standards' arrange/act distinction.
		// eslint-disable-next-line playwright/no-wait-for-timeout, no-restricted-syntax -- arrange-phase wait, see comment above
		await page.waitForTimeout(1_100);
		await createUser(`admin-sort-tie-newer-${seed}@e2e.griddle.test`, 'TestPassword123!', newerName);

		await navigateToAdminPage(page, '/admin/customers', 'Customer Management');
		await page.getByTestId('customer-search').fill(customerPrefix);

		const tableBody = page.getByTestId('customers-table-body');
		await expect
			.poll(async () => tableBody.getByRole('row').count(), {
				message: 'expected exactly the two seeded same-severity customers'
			})
			.toBe(2);

		const sortBillingHealth = page.getByTestId('sort-billing-health');
		await sortBillingHealth.click();
		await expect(sortBillingHealth).toContainText('sorted');

		const sortedRows = await tableBody.getByRole('row').evaluateAll((rows) =>
			rows.map((row) => ({
				customerName: row.querySelector('a')?.textContent?.trim() ?? '',
				billingHealth: row
					.querySelector('[data-testid^="billing-health-badge-"]')
					?.textContent?.trim() ?? ''
			}))
		);

		expect(sortedRows).toHaveLength(2);
		expect(sortedRows.map((row) => row.customerName)).toEqual([newerName, olderName]);
		expect(sortedRows[0]?.billingHealth).toBe(sortedRows[1]?.billingHealth);
	});

	test('Customer list exposes billing-health and last-activity columns', async ({
		page,
		createUser
	}) => {
		const seed = Date.now();
		const customerPrefix = `Admin Billing Health ${seed}`;
		const firstName = `${customerPrefix} First`;
		const secondName = `${customerPrefix} Second`;

		await createUser(
			`admin-billing-health-suspend-${seed}@e2e.griddle.test`,
			'TestPassword123!',
			firstName
		);
		await createUser(
			`admin-billing-health-active-${seed}@e2e.griddle.test`,
			'TestPassword123!',
			secondName
		);

		await navigateToAdminPage(page, '/admin/customers', 'Customer Management');
		await page.getByTestId('customer-search').fill(customerPrefix);

		const tableBody = page.getByTestId('customers-table-body');
		await expect(tableBody).toBeVisible();
		await expect
			.poll(async () => tableBody.getByRole('row').count(), {
				message: 'expected exactly the two seeded customers in the filtered list'
			})
			.toBe(2);

		const sortBillingHealth = page.getByTestId('sort-billing-health');
		await expect(sortBillingHealth).toBeVisible();
		const firstRow = tableBody.getByRole('row').first();
		await expect(firstRow.getByTestId('index-count')).toHaveText('—');
		// Badge and last-activity cells use per-customer testid suffixes
		// (billing-health-badge-<id>, last-activity-cell-<id>), so scope by
		// data-testid prefix within the row to avoid the em-dash collision
		// between index-count and last-activity (both render '—' for an
		// unseeded customer).
		await expect(firstRow.getByTestId(/^billing-health-badge-/)).toHaveText(
			/^(Green|Yellow|Red|Grey)$/
		);
		await expect(firstRow.getByTestId(/^last-activity-cell-/)).toHaveText(
			/^(—|just now|\d+m ago|\d+h ago|\d+ days ago)$/
		);

		await sortBillingHealth.click();
		await expect(sortBillingHealth).toContainText('sorted');

		const sortedRows = await tableBody.getByRole('row').evaluateAll((rows) =>
			rows.map((row) => ({
				rowTestId: row.getAttribute('data-testid') ?? '',
				billingHealth: row
					.querySelector('[data-testid^="billing-health-badge-"]')
					?.textContent?.trim() ?? ''
			}))
		);
		expect(sortedRows.length).toBeGreaterThan(1);

		const sortedRanks = sortedRows.map(({ rowTestId, billingHealth }) => {
			expect(rowTestId).toMatch(/^customer-row-/);
			const rank = BILLING_HEALTH_LABEL_RANK[billingHealth];
			expect(rank).not.toBeUndefined();
			return rank;
		});
		expect(sortedRanks).toEqual([...sortedRanks].sort((left, right) => left - right));

		const sortedLabels = sortedRows.map((row) => row.billingHealth);
		const distinctLabelsInRenderedOrder = sortedLabels.filter(
			(label, index) => index === 0 || sortedLabels[index - 1] !== label
		);
		expect(distinctLabelsInRenderedOrder.length).toBeGreaterThan(0);

		const expectedDistinctLabelOrder = ['Red', 'Yellow', 'Grey', 'Green'].filter((label) =>
			distinctLabelsInRenderedOrder.includes(label)
		);
		expect(distinctLabelsInRenderedOrder).toEqual(expectedDistinctLabelOrder);
	});
});
