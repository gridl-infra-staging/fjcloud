/**
 * Smoke - Customer release surfaces
 *
 * Verifies the authenticated W3A/W3B index-detail tab surfaces against the
 * repo-owned local Playwright stack: canonical tab visibility, overview
 * export/import controls and export payload shape, plus a seeded Metrics-ready
 * index whose KPI values are asserted against the same `$lib/format` contract
 * the Metrics tab renders with.
 */

import type { Download, Locator, Page } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';
import { formatNumber } from '../../../src/lib/format';
import { INDEX_DETAIL_TABS } from '../../../src/routes/console/indexes/[name]/index_detail_tabs';
import { chooseFirstAvailableRegion } from '../../fixtures/create_index_form_helpers';

type IndexDetailTab = (typeof INDEX_DETAIL_TABS)[number];

type IndexSelection = {
	name: string;
	createdBySpec: boolean;
};

const METRICS_TAB = (() => {
	const tab = INDEX_DETAIL_TABS.find((candidate) => candidate.id === 'metrics');
	if (!tab) {
		throw new Error('Canonical index-detail tabs must include Metrics.');
	}
	return tab;
})();

const PANEL_CONTENT_ANCHOR_SELECTOR = [
	'button',
	'a[href]',
	'input:not([type="hidden"])',
	'textarea',
	'select',
	'canvas',
	'img',
	'svg',
	'[role="alert"]',
	'[role="button"]',
	'[role="grid"]',
	'[role="link"]',
	'[role="list"]',
	'[role="status"]',
	'[role="table"]',
	'[data-testid]'
].join(', ');

async function chooseOrCreateIndex(page: Page): Promise<IndexSelection> {
	await page.goto('/console/indexes');
	await expect(page.getByRole('heading', { name: 'Indexes' })).toBeVisible();

	const existingIndexLink = page.getByRole('table').getByRole('link').first();
	if (await existingIndexLink.isVisible().catch(() => false)) {
		const indexName = (await existingIndexLink.textContent())?.trim() ?? '';
		expect(indexName.length, 'existing index link must expose a non-empty name').toBeGreaterThan(0);
		await existingIndexLink.click();
		return { name: indexName, createdBySpec: false };
	}

	const indexName = `customer_release_smoke_${Date.now()}`;
	await page.getByRole('button', { name: 'Create Index' }).click();
	const createForm = page.getByTestId('create-index-form');
	await expect(createForm).toBeVisible();
	await createForm.getByLabel('Index name').fill(indexName);
	await chooseFirstAvailableRegion(page);
	await page.getByRole('button', { name: 'Create', exact: true }).click();
	await expect(page).toHaveURL(
		new RegExp(`/console/indexes/${encodeURIComponent(indexName)}(?:\\?|$)`),
		{ timeout: 30_000 }
	);
	return { name: indexName, createdBySpec: true };
}

async function openIndexDetailRoute(
	page: Page,
	indexName: string,
	initialTab: IndexDetailTab
): Promise<void> {
	const expectedPathname = `/console/indexes/${encodeURIComponent(indexName)}`;
	await page.goto(`${expectedPathname}?tab=${initialTab.id}`);
	await expect(
		page,
		`${initialTab.label} deep link should stay on the authenticated index detail route`
	).toHaveURL(
		(url) => url.pathname === expectedPathname && url.searchParams.get('tab') === initialTab.id,
		{ timeout: 10_000 }
	);
	await expect(page.getByRole('heading', { name: indexName, exact: true })).toBeVisible({
		timeout: 10_000
	});
}

async function selectIndexDetailTab(page: Page, tab: IndexDetailTab): Promise<void> {
	const tabButton = page.getByRole('tab', { name: tab.label, exact: true });
	await tabButton.click();
	await expect(page, `${tab.label} selection should update the tab query param`).toHaveURL(
		(url) => url.searchParams.get('tab') === tab.id,
		{ timeout: 10_000 }
	);
	await expect(tabButton).toHaveAttribute('aria-selected', 'true');
}

async function assertCanonicalTabStrip(page: Page): Promise<void> {
	const indexDetailTabs = page.getByRole('tablist', { name: 'Index detail sections' });
	await expect(indexDetailTabs, 'index detail should finish rendering its tab strip').toBeVisible({
		timeout: 10_000
	});
	const tabNames = await indexDetailTabs
		.getByRole('tab')
		.evaluateAll((tabs) => tabs.map((tab) => tab.textContent?.trim() ?? ''));
	expect(tabNames, `index detail tabs rendered incorrectly; tabs=${tabNames.join(', ')}`).toEqual(
		INDEX_DETAIL_TABS.map((tab) => tab.label)
	);
}

async function assertPanelRenderHealth(panel: Locator, tab: IndexDetailTab): Promise<void> {
	const visibleText = (await panel.innerText()).trim();
	expect(visibleText, `${tab.label} panel should not expose broken render sentinels`).not.toMatch(
		/(?:Error 500|\bundefined\b|\bnull\b|\bNaN\b)/
	);
	const hasVisibleContentAnchor = await panel
		.locator(PANEL_CONTENT_ANCHOR_SELECTOR)
		.evaluateAll((elements) =>
			elements.some((element) => {
				const style = window.getComputedStyle(element);
				const rect = element.getBoundingClientRect();
				return (
					style.display !== 'none' &&
					style.visibility !== 'hidden' &&
					rect.width > 0 &&
					rect.height > 0
				);
			})
		);
	expect(
		visibleText.length > 0 || hasVisibleContentAnchor,
		`${tab.label} panel should expose visible text or an interactive/content anchor`
	).toBe(true);
}

// Storage renders through `formatBytes` ("200.0 KB"); request/write counts render
// through `formatNumber` (locale digit groups). Each KPI card testid wraps its
// label paragraph followed by its value paragraph, so the normalized card text is
// "<label> <value>" — the value patterns below pin the value segment exactly.
const STORAGE_KPI_VALUE_PATTERN = /^Storage \d[\d,]*(?:\.\d+)? (?:B|KB|MB|GB)$/;
const SEARCH_REQUESTS_KPI_VALUE_PATTERN = /^Search requests \d[\d,]*$/;
const WRITE_OPERATIONS_KPI_VALUE_PATTERN = /^Write operations \d[\d,]*$/;

/**
 * Assert the Metrics tab surface.
 *
 * Single owner for the Metrics assertion contract with two modes:
 *  - `expectedDocumentCount` omitted (overview all-tabs loop): a freshly-created
 *    index legitimately renders the empty metrics state or a tab-local
 *    unavailable alert, so the presence-tolerant OR stays intact.
 *  - `expectedDocumentCount` provided (seeded Metrics-ready index): the KPI grid
 *    MUST be populated; empty-state and the unavailable alert are failures, and
 *    the Documents KPI must equal the seeded count via `formatNumber`.
 */
async function assertMetricsSurface(
	metricsPanel: Locator,
	expectedDocumentCount?: number
): Promise<void> {
	await expect(metricsPanel.getByTestId('metrics-refresh-btn')).toBeVisible();

	const kpiGrid = metricsPanel.getByTestId('metrics-kpi-grid');
	const emptyState = metricsPanel.getByTestId('metrics-empty-state');
	const unavailableAlert = metricsPanel.getByRole('alert');

	if (expectedDocumentCount === undefined) {
		const hasKpiGrid = await kpiGrid.isVisible().catch(() => false);
		const hasEmptyState = await emptyState.isVisible().catch(() => false);
		const hasUnavailableAlert = await unavailableAlert.isVisible().catch(() => false);
		expect(
			hasKpiGrid || hasEmptyState || hasUnavailableAlert,
			'metrics tab should expose KPI cards, the empty metrics state, or the tab-local unavailable alert'
		).toBe(true);
		if (hasUnavailableAlert) {
			await expect(unavailableAlert).toContainText('Metrics unavailable');
			await expect(unavailableAlert).toContainText(/HTTP \d+/);
			return;
		}

		await expect(metricsPanel.getByTestId('metrics-fetched-at')).toBeVisible();
		if (hasKpiGrid) {
			await expect(metricsPanel.getByTestId('metrics-kpi-documents')).toBeVisible();
			await expect(metricsPanel.getByTestId('metrics-kpi-storage')).toBeVisible();
			await expect(metricsPanel.getByTestId('metrics-kpi-search-requests')).toBeVisible();
			await expect(metricsPanel.getByTestId('metrics-kpi-write-operations')).toBeVisible();
		}
		return;
	}

	// Seeded Metrics-ready index: reject empty-state and the tab-local unavailable
	// alert as success, then assert concrete KPI values.
	await expect(
		unavailableAlert,
		'seeded metrics index must not render the tab-local unavailable alert'
	).toHaveCount(0);
	await expect(
		emptyState,
		'seeded metrics index must not render the empty metrics state'
	).toHaveCount(0);
	await expect(kpiGrid).toBeVisible();
	await expect(metricsPanel.getByTestId('metrics-fetched-at')).toBeVisible();

	await expect(metricsPanel.getByTestId('metrics-kpi-documents')).toHaveText(
		`Documents ${formatNumber(expectedDocumentCount)}`
	);
	await expect(metricsPanel.getByTestId('metrics-kpi-storage')).toHaveText(
		STORAGE_KPI_VALUE_PATTERN
	);
	await expect(metricsPanel.getByTestId('metrics-kpi-search-requests')).toHaveText(
		SEARCH_REQUESTS_KPI_VALUE_PATTERN
	);
	await expect(metricsPanel.getByTestId('metrics-kpi-write-operations')).toHaveText(
		WRITE_OPERATIONS_KPI_VALUE_PATTERN
	);
}

async function assertIndexDetailTabSurface(page: Page, tab: IndexDetailTab): Promise<void> {
	await selectIndexDetailTab(page, tab);
	const panel = page.getByTestId(tab.panelTestId);
	await expect(panel, `${tab.label} selection should render its owned panel`).toBeVisible({
		timeout: 10_000
	});
	await assertPanelRenderHealth(panel, tab);
	if (tab.id === METRICS_TAB.id) {
		await assertMetricsSurface(panel);
	}
}

async function assertSeededMetricsTab(
	page: Page,
	seededIndexName: string,
	expectedDocumentCount: number
): Promise<void> {
	await openIndexDetailRoute(page, seededIndexName, INDEX_DETAIL_TABS[0]);
	await assertCanonicalTabStrip(page);
	await selectIndexDetailTab(page, METRICS_TAB);
	const metricsPanel = page.getByTestId(METRICS_TAB.panelTestId);
	await expect(
		metricsPanel,
		'Metrics selection should render its owned panel for the seeded index'
	).toBeVisible({ timeout: 10_000 });
	await assertMetricsSurface(metricsPanel, expectedDocumentCount);
}

async function assertAllIndexDetailTabSurfaces(page: Page, indexName: string): Promise<void> {
	await openIndexDetailRoute(page, indexName, INDEX_DETAIL_TABS[0]);
	await assertCanonicalTabStrip(page);
	for (const tab of INDEX_DETAIL_TABS) {
		await assertIndexDetailTabSurface(page, tab);
	}
}

async function readDownloadText(download: Download): Promise<string> {
	const stream = await download.createReadStream();
	if (!stream) return '';
	const chunks: Buffer[] = [];
	for await (const chunk of stream) {
		chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
	}
	return Buffer.concat(chunks).toString('utf8');
}

function ownerPreservesFilenameSegmentVerbatim(indexName: string): boolean {
	// Stay conservative: only opt into exact-name assertions when the owner
	// would preserve the existing segment without trimming or underscore cleanup.
	return (
		indexName.trim() === indexName &&
		indexName.length > 0 &&
		/^[A-Za-z0-9._-]+$/.test(indexName) &&
		!indexName.startsWith('.') &&
		!indexName.startsWith('_') &&
		!indexName.endsWith('_')
	);
}

async function assertOverviewExport(page: Page, selection: IndexSelection): Promise<void> {
	await page.goto(`/console/indexes/${encodeURIComponent(selection.name)}?tab=overview`);
	const dataManagement = page.getByTestId('overview-data-management');
	await expect(dataManagement).toBeVisible();
	await expect(dataManagement.getByTestId('overview-export-btn')).toBeVisible();
	await expect(dataManagement.getByTestId('overview-import-btn')).toBeVisible();

	const downloadPromise = page.waitForEvent('download');
	await dataManagement.getByTestId('overview-export-btn').click();
	const download = await downloadPromise;
	const dayStamp = new Date().toISOString().slice(0, 10).replace(/-/g, '');
	const filename = download.suggestedFilename();
	const suffix = `-export-${dayStamp}.json`;
	if (selection.createdBySpec || ownerPreservesFilenameSegmentVerbatim(selection.name)) {
		expect(filename).toBe(`${selection.name}-export-${dayStamp}.json`);
	} else {
		expect(filename.endsWith(suffix)).toBe(true);
		expect(filename.slice(0, -suffix.length).length).toBeGreaterThan(0);
	}

	const payload = JSON.parse(await readDownloadText(download)) as unknown;
	expect(Array.isArray(payload), 'overview export payload should be a JSON array').toBe(true);
}

test('authenticated customer index detail exposes canonical tabs and overview data management', async ({
	page,
	seedMetricsSearchableIndex
}) => {
	// Seeding waits for the metering pipeline to report the expected document
	// count (up to a ~130s poll budget after the ~60s scrape interval), so this
	// test needs a generous wall-clock budget on top of the tab/export walk.
	test.setTimeout(240_000);

	const seeded = await seedMetricsSearchableIndex(`customer_release_metrics_${Date.now()}`);
	// `seeded.metrics.expectedDocumentCount` is the only source of truth for the
	// Documents KPI expected value.
	await assertSeededMetricsTab(page, seeded.name, seeded.metrics.expectedDocumentCount);

	const selection = await chooseOrCreateIndex(page);
	expect(selection.name.length, 'selected index name should be non-empty').toBeGreaterThan(0);
	await assertAllIndexDetailTabSurfaces(page, selection.name);
	await assertOverviewExport(page, selection);
});
