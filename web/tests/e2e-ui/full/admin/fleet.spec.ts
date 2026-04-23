/**
 * Full — Admin Fleet
 *
 * Verifies the admin panel fleet overview:
 *   - Admin login page renders correctly
 *   - Admin login with valid key reaches /admin/fleet
 *   - Fleet Overview page renders with the correct heading
 *   - Admin nav links to other sections are visible
 *
 * Auth: uses .auth/admin.json (loaded via chromium:admin project).
 */

import { expect, test } from '../../../fixtures/fixtures';

async function gotoFleetWithRows(page: import('@playwright/test').Page): Promise<number> {
	await page.goto('/admin/fleet');
	await expect(page.getByRole('heading', { name: 'Fleet Overview' })).toBeVisible();

	await expect
		.poll(
			async () => {
				const rowCount = await page.getByTestId('fleet-table-body').locator('tr').count();
				if (rowCount > 0) {
					return rowCount;
				}

				// The fleet loader intentionally falls back to an empty array on fetch
				// errors, so retry when the live local stack briefly returns the empty
				// state even though the backend fleet endpoint is seeded.
				await expect(page.getByText('No deployments found.')).toBeVisible();
				await page.reload();
				await expect(page.getByRole('heading', { name: 'Fleet Overview' })).toBeVisible();
				return 0;
			},
			{
				intervals: [1_000, 2_000, 3_000, 4_000],
				message: 'seeded fleet rows should render without arbitrary sleeps',
				timeout: 20_000
			}
		)
		.toBeGreaterThan(0);

	return page.getByTestId('fleet-table-body').locator('tr').count();
}

async function gotoFleetWithVmRows(page: import('@playwright/test').Page): Promise<number> {
	await page.goto('/admin/fleet');
	await expect(page.getByRole('heading', { name: 'Fleet Overview' })).toBeVisible();

	await expect
		.poll(
			async () => {
				const rowCount = await page.getByTestId('vm-table-body').locator('tr').count();
				if (rowCount > 0) {
					return rowCount;
				}

				// VM inventory can briefly be empty while the local stack settles.
				await page.reload();
				await expect(page.getByRole('heading', { name: 'Fleet Overview' })).toBeVisible();
				return 0;
			},
			{
				intervals: [1_000, 2_000, 3_000, 4_000],
				message: 'seeded VM inventory rows should render for VM detail drill-down',
				timeout: 20_000
			}
		)
		.toBeGreaterThan(0);

	return page.getByTestId('vm-table-body').locator('tr').count();
}

test.describe('Admin fleet overview', () => {
	test('fleet overview page renders after admin login', async ({ page }) => {
		// Auth state is pre-loaded from .auth/admin.json
		await page.goto('/admin/fleet');

		// Assert: page-specific heading (not just nav item text)
		await expect(page.getByRole('heading', { name: 'Fleet Overview' })).toBeVisible();
	});

	test('seeded fleet rows render and filter controls narrow that same visible row set', async ({
		page
	}) => {
		const initialRowCount = await gotoFleetWithRows(page);
		const tableBody = page.getByTestId('fleet-table-body');
		const rows = tableBody.locator('tr');
		expect(
			initialRowCount,
			'missing seeded fleet rows required to prove fleet-table-body rendering'
		).toBeGreaterThan(0);
		await expect(rows.first()).toBeVisible();

		const rowDetails = await Promise.all(
			Array.from({ length: initialRowCount }, async (_, index) => {
				const row = rows.nth(index);
				return {
					shortId: (await row.locator('td').nth(0).textContent())?.trim() ?? '',
					provider: (await row.locator('td').nth(1).textContent())?.trim() ?? '',
					status: (await row.locator('td').nth(3).textContent())?.trim() ?? ''
				};
			})
		);
		const uniqueStatuses = [...new Set(rowDetails.map((row) => row.status).filter(Boolean))];
		const uniqueProviders = [...new Set(rowDetails.map((row) => row.provider).filter(Boolean))];
		const statusProbeRow = rowDetails.find((row) => {
			const matchingStatusCount = rowDetails.filter(
				(candidate) => candidate.status === row.status
			).length;
			return row.shortId !== '' && row.status !== '' && matchingStatusCount < initialRowCount;
		});
		const providerProbeRow = rowDetails.find((row) => {
			const matchingProviderCount = rowDetails.filter(
				(candidate) => candidate.provider === row.provider
			).length;
			return row.shortId !== '' && row.provider !== '' && matchingProviderCount < initialRowCount;
		});
		const baselineProbeRow =
			statusProbeRow ?? providerProbeRow ?? rowDetails.find((row) => row.shortId !== '');
		expect(baselineProbeRow, 'missing seeded fleet rows with a visible short id').toBeDefined();
		const baselineShortId = baselineProbeRow!.shortId;

		// Seeded page-body content should be visible before any filters are applied.
		await expect(tableBody).toContainText(baselineShortId);

		if (uniqueStatuses.length > 1) {
			expect(
				statusProbeRow,
				'missing seeded fleet status variety required to prove status filtering'
			).toBeDefined();
			const seededStatus = statusProbeRow!.status;
			const matchingStatusCount = rowDetails.filter((row) => row.status === seededStatus).length;

			await page.getByTestId('status-filter').selectOption(seededStatus);
			await expect(rows).toHaveCount(matchingStatusCount);
			expect(matchingStatusCount).toBeLessThan(initialRowCount);
			await expect(tableBody).toContainText(statusProbeRow!.shortId);

			for (let index = 0; index < matchingStatusCount; index += 1) {
				await expect(rows.nth(index).locator('td').nth(3)).toContainText(seededStatus);
			}
		} else {
			await page.getByTestId('status-filter').selectOption(uniqueStatuses[0] ?? 'all');
			await expect(rows).toHaveCount(initialRowCount);
		}

		await page.getByTestId('status-filter').selectOption('all');
		if (uniqueProviders.length > 1) {
			expect(
				providerProbeRow,
				'missing seeded fleet provider variety required to prove provider filtering'
			).toBeDefined();
			const seededProvider = providerProbeRow!.provider;
			const matchingProviderCount = rowDetails.filter(
				(row) => row.provider === seededProvider
			).length;

			await page.getByTestId('provider-filter').selectOption(seededProvider);
			await expect(rows).toHaveCount(matchingProviderCount);
			expect(matchingProviderCount).toBeLessThan(initialRowCount);
			await expect(tableBody).toContainText(providerProbeRow!.shortId);

			for (let index = 0; index < matchingProviderCount; index += 1) {
				await expect(rows.nth(index).locator('td').nth(1)).toContainText(seededProvider);
			}
		} else {
			await page.getByTestId('provider-filter').selectOption(uniqueProviders[0] ?? 'all');
			await expect(rows).toHaveCount(initialRowCount);
		}
	});

	test('VM infrastructure hostname opens the VM detail page', async ({ page }) => {
		await gotoFleetWithVmRows(page);

		const vmTable = page.getByTestId('vm-table-body');
		const firstHostnameLink = vmTable.getByRole('link').first();
		await expect(firstHostnameLink).toBeVisible();
		const hostname = (await firstHostnameLink.textContent())?.trim() ?? '';
		expect(hostname, 'VM hostname link should have visible text').not.toBe('');

		await firstHostnameLink.click();

		await expect(page).toHaveURL(/\/admin\/fleet\/[^/]+$/);
		await expect(page.getByRole('heading', { name: hostname })).toBeVisible();
		await expect(page.getByRole('heading', { name: 'VM Info' })).toBeVisible();
		await expect(page.getByRole('heading', { name: /Indexes on this VM/ })).toBeVisible();
		await expect(page.getByRole('link', { name: '← Fleet' })).toHaveAttribute(
			'href',
			'/admin/fleet'
		);
	});

	test('admin navigation links are all present', async ({ page }) => {
		await page.goto('/admin/fleet');

		await expect(page.getByRole('link', { name: 'Fleet' })).toBeVisible();
		await expect(page.getByRole('link', { name: 'Customers' })).toBeVisible();
		await expect(page.getByRole('link', { name: 'Migrations' })).toBeVisible();
		await expect(page.getByRole('link', { name: 'Replicas' })).toBeVisible();
		await expect(page.getByRole('link', { name: 'Billing' })).toBeVisible();
		await expect(page.getByRole('link', { name: 'Alerts' })).toBeVisible();
	});

	test('Customers nav link leads to the admin customers page', async ({ page }) => {
		await page.goto('/admin/fleet');

		await expect(page.getByRole('link', { name: 'Customers' })).toHaveAttribute(
			'href',
			'/admin/customers'
		);
		await page.goto('/admin/customers');

		await expect(page).toHaveURL(/\/admin\/customers/);
		await expect(page.getByRole('heading', { name: 'Customer Management' })).toBeVisible();
	});

	test('Replicas nav link leads to the admin replicas page', async ({ page }) => {
		await page.goto('/admin/fleet');

		await expect(page.getByRole('link', { name: 'Replicas' })).toHaveAttribute(
			'href',
			'/admin/replicas'
		);
		await page.goto('/admin/replicas');

		await expect(page).toHaveURL(/\/admin\/replicas/);
		await expect(page.getByRole('heading', { name: /Replica/i })).toBeVisible();
	});
});

test.describe('Admin login page', () => {
	// These tests bypass stored auth to verify the login page directly
	test.use({ storageState: { cookies: [], origins: [] } });

	test('admin login page renders', async ({ page }) => {
		await page.goto('/admin/login');

		await expect(page.getByRole('heading', { name: 'Admin Login' })).toBeVisible();
		await expect(page.getByLabel('Admin Key')).toBeVisible();
		await expect(page.getByRole('button', { name: 'Log In' })).toBeVisible();
	});

	test('wrong admin key shows error', async ({ page }) => {
		await page.goto('/admin/login');

		await page.getByLabel('Admin Key').fill('wrong-key-123');
		await page.getByRole('button', { name: 'Log In' }).click();

		await expect(page.getByRole('alert')).toBeVisible({ timeout: 5_000 });
		await expect(page).toHaveURL(/\/admin\/login/);
	});

	test('unauthenticated visit to /admin/fleet redirects to /admin/login', async ({ page }) => {
		await page.goto('/admin/fleet');

		await expect(page).toHaveURL(/\/admin\/login/);
	});
});
