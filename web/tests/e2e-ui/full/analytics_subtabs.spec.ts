import type { Page } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';

type SeedIndexFn = (name: string, region?: string) => Promise<void>;

type AnalyticsSubtabExpectation = {
	testId: string;
	label: string;
};

const ANALYTICS_SUBTAB_EXPECTATIONS: AnalyticsSubtabExpectation[] = [
	{ testId: 'analytics-subtab-overview', label: 'Overview' },
	{ testId: 'analytics-subtab-searches', label: 'Searches' },
	{ testId: 'analytics-subtab-no-results', label: 'No Results' },
	{ testId: 'analytics-subtab-filters', label: 'Filters' },
	{ testId: 'analytics-subtab-conversions', label: 'Conversions' },
	{ testId: 'analytics-subtab-devices', label: 'Devices' },
	{ testId: 'analytics-subtab-geography', label: 'Geography' }
];

async function openAnalyticsTabWithDateWindow(
	page: Page,
	seedIndex: SeedIndexFn,
	testRegion: string,
	namePrefix: string,
	query = 'tab=analytics&startDate=2026-02-19&endDate=2026-02-25'
) {
	const indexName = `${namePrefix}-${Date.now()}`;
	await seedIndex(indexName, testRegion);
	await page.goto(`/console/indexes/${encodeURIComponent(indexName)}?${query}`);
	await expect(page.getByRole('heading', { name: indexName })).toBeVisible({ timeout: 10_000 });
	await expect(page.getByTestId('tab-analytics')).toHaveAttribute('aria-selected', 'true');
	return indexName;
}

async function expectAnalyticsUrlState(page: Page, indexName: string, expectedSubtab: string) {
	await expect(page).toHaveURL(new RegExp(`/console/indexes/${encodeURIComponent(indexName)}\\?`));
	const parsedUrl = new URL(page.url());
	expect(parsedUrl.searchParams.get('tab')).toBe('analytics');
	expect(parsedUrl.searchParams.get('subtab')).toBe(expectedSubtab);
	// Analytics navigation now uses `period` as the single source of truth.
	// Legacy explicit date params are intentionally stripped from URL state.
	expect(parsedUrl.searchParams.get('startDate')).toBeNull();
	expect(parsedUrl.searchParams.get('endDate')).toBeNull();
}

test.describe('Analytics subtab shell', () => {
	test.describe.configure({ timeout: 90_000 });

	test('renders seven URL-backed subtabs and preserves query params', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		const indexName = await openAnalyticsTabWithDateWindow(
			page,
			seedIndex,
			testRegion,
			'e2e-analytics-subtabs'
		);

		for (const expectation of ANALYTICS_SUBTAB_EXPECTATIONS) {
			const tab = page.getByTestId(expectation.testId);
			await expect(tab).toBeVisible();
			await expect(tab).toHaveText(expectation.label);
		}

		const geographySubtab = page.getByTestId('analytics-subtab-geography');
		await geographySubtab.click();
		await expect(geographySubtab).toHaveAttribute('aria-selected', 'true');
		await expectAnalyticsUrlState(page, indexName, 'geography');

		await page.goto(
			`/console/indexes/${encodeURIComponent(indexName)}?tab=analytics&subtab=geography&period=30d&startDate=2026-02-19&endDate=2026-02-25`
		);
		const deepLinkedGeographySubtab = page.getByTestId('analytics-subtab-geography');
		await expect(deepLinkedGeographySubtab).toHaveAttribute('aria-selected', 'true');

		await page.getByTestId('analytics-subtab-devices').click();
		await expectAnalyticsUrlState(page, indexName, 'devices');
		expect(new URL(page.url()).searchParams.get('period')).toBe('30d');

		await page.reload();
		await expect(page.getByTestId('analytics-subtab-devices')).toHaveAttribute(
			'aria-selected',
			'true'
		);
		await expectAnalyticsUrlState(page, indexName, 'devices');
		expect(new URL(page.url()).searchParams.get('period')).toBe('30d');
	});
});
