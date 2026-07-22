/**
 * Full — Admin Fleet
 *
 * Verifies the admin panel fleet overview:
 *   - Fleet Overview page renders with the correct heading
 *   - Admin nav links to other sections are visible
 *
 * Auth: uses .auth/admin.json (loaded via chromium:admin project).
 */

import { expect, test } from '../../../fixtures/fixtures';
import type { VmHostMetricsResponse } from '../../../../src/lib/admin-client';
import { formatBytes } from '../../../../src/lib/format';
import { utilPercent } from '../../../../src/lib/vm-capacity';

type ArrangeFleetSeedParams = {
	createUser: (
		email: string,
		password: string,
		name?: string
	) => Promise<{ customerId: string; token: string; email: string; password: string }>;
	ensureLocalSharedVmInventory: (region: string) => Promise<void>;
	seedAdminDeployment: (
		customer: { customerId: string; token: string; email: string; password: string },
		options?: { region?: string }
	) => Promise<unknown>;
	testRegion: string;
};

async function arrangeSeededFleet({
	createUser,
	ensureLocalSharedVmInventory,
	seedAdminDeployment,
	testRegion
}: ArrangeFleetSeedParams): Promise<string> {
	const seed = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
	const seededRegion = `${testRegion}-${seed}`;
	await ensureLocalSharedVmInventory(seededRegion);
	const customer = await createUser(
		`fleet-capacity-${seed}@e2e.griddle.test`,
		'TestPassword123!',
		`Fleet Capacity ${seed}`
	);
	await seedAdminDeployment(customer, { region: seededRegion });
	return seededRegion;
}

async function gotoFleetWithRows(page: import('@playwright/test').Page): Promise<number> {
	await page.goto('/admin/fleet');
	await expect(page.getByRole('heading', { name: 'Fleet Overview' })).toBeVisible();
	const fleetRows = page.getByTestId(/^fleet-row-/);

	await expect
		.poll(
			async () => {
				const rowCount = await fleetRows.count();
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

	return fleetRows.count();
}

async function gotoFleetWithVmRows(page: import('@playwright/test').Page): Promise<number> {
	await page.goto('/admin/fleet');
	await expect(page.getByRole('heading', { name: 'Fleet Overview' })).toBeVisible();
	const capacityRows = page.getByTestId(/^capacity-row-/);

	await expect
		.poll(
			async () => {
				const rowCount = await capacityRows.count();
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

	return capacityRows.count();
}

function expectedHostMetricCells(
	metrics: VmHostMetricsResponse | null
): [string, string, string, string] {
	if (!metrics) {
		return ['No host data', 'No host data', 'No host data', 'No host data'];
	}
	const disk =
		metrics.disk_used_bytes === null ||
		metrics.disk_total_bytes === null ||
		metrics.disk_total_bytes <= 0
			? '—'
			: `${utilPercent(metrics.disk_used_bytes, metrics.disk_total_bytes)}%`;
	const ram =
		metrics.mem_total_bytes <= 0
			? '—'
			: `${utilPercent(metrics.mem_used_bytes, metrics.mem_total_bytes)}%`;
	return [
		disk,
		`${metrics.cpu_pct}%`,
		ram,
		`RX total ${formatBytes(metrics.net_rx_bytes)} / TX total ${formatBytes(metrics.net_tx_bytes)}`
	];
}

test.describe('Admin fleet overview', () => {
	test('fleet overview page renders after admin login', async ({ page }) => {
		// Auth state is pre-loaded from .auth/admin.json
		await page.goto('/admin/fleet');

		// Assert: page-specific heading (not just nav item text)
		await expect(page.getByRole('heading', { name: 'Fleet Overview' })).toBeVisible();
	});

	test('seeded fleet rows render and filter controls narrow that same visible row set', async ({
		page,
		createUser,
		ensureLocalSharedVmInventory,
		seedAdminDeployment,
		testRegion
	}) => {
		await arrangeSeededFleet({
			createUser,
			ensureLocalSharedVmInventory,
			seedAdminDeployment,
			testRegion
		});
		const initialRowCount = await gotoFleetWithRows(page);
		await page.getByRole('checkbox', { name: 'Auto-refresh (5s)' }).uncheck();
		const tableBody = page.getByTestId('fleet-table-body');
		const rows = page.getByTestId(/^fleet-row-/);
		expect(
			initialRowCount,
			'missing seeded fleet rows required to prove fleet-table-body rendering'
		).toBeGreaterThan(0);
		await expect(rows.first()).toBeVisible();

		const rowDetails = await Promise.all(
			Array.from({ length: initialRowCount }, async (_, index) => {
				const cellText = await rows.nth(index).getByRole('cell').allTextContents();
				return {
					shortId: cellText[0]?.trim() ?? '',
					provider: cellText[1]?.trim() ?? '',
					status: cellText[3]?.trim() ?? ''
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
			await expect(tableBody.getByRole('cell', { name: seededStatus, exact: true })).toHaveCount(
				matchingStatusCount
			);
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
			await expect(tableBody.getByRole('cell', { name: seededProvider, exact: true })).toHaveCount(
				matchingProviderCount
			);
		} else {
			await page.getByTestId('provider-filter').selectOption(uniqueProviders[0] ?? 'all');
			await expect(rows).toHaveCount(initialRowCount);
		}
	});

	test('VM infrastructure hostname opens the VM detail page', async ({
		page,
		createUser,
		ensureLocalSharedVmInventory,
		seedAdminDeployment,
		testRegion
	}) => {
		const seededRegion = await arrangeSeededFleet({
			createUser,
			ensureLocalSharedVmInventory,
			seedAdminDeployment,
			testRegion
		});
		await gotoFleetWithVmRows(page);
		await page.getByTestId('auto-refresh-toggle').uncheck();

		const vmTable = page.getByTestId('capacity-table-body');
		const seededHostnameLink = vmTable.getByRole('link', { name: `local-dev-${seededRegion}` });
		await expect(seededHostnameLink).toBeVisible();
		const hostname = (await seededHostnameLink.textContent())?.trim() ?? '';
		expect(hostname, 'VM hostname link should have visible text').not.toBe('');
		const detailHref = await seededHostnameLink.getAttribute('href');
		expect(detailHref, 'VM hostname link should target the VM detail route').toMatch(
			/^\/admin\/fleet\/[^/]+$/
		);

		await Promise.all([page.waitForURL(`**${detailHref}`), seededHostnameLink.click()]);

		const vmInfoSection = page.getByTestId('vm-info-section');
		await expect(vmInfoSection).toBeVisible({ timeout: 30_000 });
		await expect(vmInfoSection).toContainText(hostname);
		await expect(page.getByRole('heading', { name: /Indexes on this VM/ })).toBeVisible();
		await expect(page.getByRole('link', { name: '← Fleet' })).toHaveAttribute(
			'href',
			'/admin/fleet'
		);
	});

	test('seeded VM capacity row and region rollup render exact capacity evidence', async ({
		page,
		createUser,
		ensureLocalSharedVmInventory,
		seedAdminDeployment,
		readAdminVmHostMetricsEvidence,
		elementHasHorizontalOverflow,
		testRegion
	}) => {
		await page.setViewportSize({ width: 390, height: 844 });
		const seededRegion = await arrangeSeededFleet({
			createUser,
			ensureLocalSharedVmInventory,
			seedAdminDeployment,
			testRegion
		});
		const hostMetricsBeforeLoad = await readAdminVmHostMetricsEvidence({ region: seededRegion });
		await gotoFleetWithVmRows(page);
		await page.getByRole('checkbox', { name: 'Auto-refresh (5s)' }).uncheck();
		const hostMetricsAfterLoad = await readAdminVmHostMetricsEvidence({
			vmId: hostMetricsBeforeLoad.vmId
		});
		const heading = page.getByRole('heading', { name: 'Fleet Overview' });
		const refreshControl = page.getByText('Auto-refresh (5s)', { exact: true });
		await expect(heading).toBeVisible();
		await expect(refreshControl).toBeVisible();
		const headingBox = await heading.boundingBox();
		const toggleBox = await refreshControl.boundingBox();
		expect(headingBox, 'mobile heading should have a rendered box').not.toBeNull();
		expect(toggleBox, 'mobile auto-refresh control should have a rendered box').not.toBeNull();
		expect(headingBox!.x + headingBox!.width).toBeLessThanOrEqual(toggleBox!.x);

		const capacityTable = page.getByTestId('capacity-table-body');
		const capacityTableScroll = page.getByTestId('capacity-table-scroll');
		expect(
			await elementHasHorizontalOverflow(capacityTableScroll),
			'mobile capacity table should preserve access through horizontal overflow'
		).toBe(true);
		const seededHostname = `local-dev-${seededRegion}`;
		const seededHostnameLink = capacityTable.getByRole('link', { name: seededHostname });
		await expect(seededHostnameLink).toBeVisible();
		const seededVmHref = await seededHostnameLink.getAttribute('href');
		expect(seededVmHref, 'seeded VM hostname should target its detail route').toMatch(
			/^\/admin\/fleet\/[^/]+$/
		);
		const seededVmId = seededVmHref!.slice('/admin/fleet/'.length);
		expect(seededVmId).toBe(hostMetricsBeforeLoad.vmId);
		const seededRow = page.getByTestId(`capacity-row-${seededVmId}`);
		await expect(seededRow).toContainText(seededHostname);
		await expect(seededRow).toContainText(seededRegion);
		await expect(seededRow).toContainText('local');
		await expect(page.getByTestId(`vm-health-${seededVmId}`)).toHaveText('unknown');
		await expect(page.getByTestId(`tenant-count-${seededVmId}`)).toHaveText('0');
		await expect(page.getByTestId(`index-count-${seededVmId}`)).toHaveText('0');

		const diskCell = page.getByTestId(`capacity-util-${seededVmId}-disk_bytes`);
		await expect(diskCell).toHaveText('0%');
		const renderedHostCells = [
			await page.getByTestId(`host-disk-${seededVmId}`).textContent(),
			await page.getByTestId(`host-cpu-${seededVmId}`).textContent(),
			await page.getByTestId(`host-ram-${seededVmId}`).textContent(),
			await page.getByTestId(`host-net-${seededVmId}`).textContent()
		].map((value) => value?.trim() ?? '') as [string, string, string, string];
		expect([
			expectedHostMetricCells(hostMetricsBeforeLoad.metrics),
			expectedHostMetricCells(hostMetricsAfterLoad.metrics)
		]).toContainEqual(renderedHostCells);

		// The seeded region is unique to this test and ensureLocalSharedVmInventory
		// creates no replica rows, so this VM deterministically has neither replica
		// role. Exact primary/replica join correctness is covered by the component test.
		await expect(page.getByRole('columnheader', { name: 'Replica placement' })).toBeVisible();
		await expect(page.getByTestId(`capacity-replicas-${seededVmId}`)).toHaveText('No replicas');
		const killControl = page.getByTestId(`kill-vm-${seededVmId}`);
		await killControl.scrollIntoViewIfNeeded();
		await expect(killControl).toBeVisible();

		const regionRollup = page.getByTestId(`region-rollup-${seededRegion}`);
		await expect(regionRollup).toBeVisible();
		await expect(regionRollup).toContainText(seededRegion);
		await expect(regionRollup).toContainText('1 VM');
		await expect(regionRollup).toContainText('Aggregate disk utilization');
		await expect(regionRollup).toContainText('0%');

		const deploymentTableScroll = page.getByTestId('deployment-table-scroll');
		expect(
			await elementHasHorizontalOverflow(deploymentTableScroll),
			'mobile deployment table should preserve access through horizontal overflow'
		).toBe(true);
		await page.getByTestId('status-filter').scrollIntoViewIfNeeded();
		await expect(page.getByTestId('status-filter')).toBeVisible();
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
