import type { Page } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';

function degradeOverviewAnalyticsPayload(html: string): string {
	return html
		.replace(/entries:0/g, 'entries:1')
		.replace(/analyticsStatus/g, 'analyticsStatusUnavailable');
}

async function openIndexDetailTab(page: Page, tabName: string) {
	const tab = page.getByRole('tab', { name: tabName, exact: true });
	await tab.scrollIntoViewIfNeeded();
	await tab.click();
	await expect(tab).toHaveAttribute('aria-selected', 'true');
}

test('Overview tab isolates analytics-summary load failure to its own alert section', async ({
	page,
	seedIndex,
	testRegion
}) => {
	const indexName = `e2e-overview-analytics-error-${Date.now()}`;
	await seedIndex(indexName, testRegion);

	await page.route(`**/console/indexes/${encodeURIComponent(indexName)}**`, async (route) => {
		const response = await route.fetch();
		const html = await response.text();
		if (html.includes('analyticsStatus:')) {
			await route.fulfill({
				status: response.status(),
				headers: response.headers(),
				body: degradeOverviewAnalyticsPayload(html)
			});
			return;
		}
		await route.fulfill({ response });
	});

	await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
	await openIndexDetailTab(page, 'Overview');

	await expect(page.getByTestId('stats-section')).toBeVisible();
	await expect(page.getByTestId('overview-data-management')).toBeVisible();
	await expect(page.getByTestId('search-widget')).toHaveCount(0);
	await expect(page.getByTestId('replicas-section')).toBeVisible();

	const analyticsSummary = page.getByTestId('overview-analytics-summary');
	await expect(analyticsSummary).toBeVisible();
	await expect(analyticsSummary.getByRole('alert')).toContainText('Analytics summary unavailable');
	await expect(analyticsSummary.getByRole('button', { name: /retry/i })).toBeVisible();
	await expect(page.getByRole('alert')).toHaveCount(1);
});
