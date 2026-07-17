import type { Page } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';

function injectLoadError(html: string, key: string, value: string): string {
	return html.replace(
		new RegExp(`(${key}:)(null|\"(?:\\\\.|[^\"])*\")`),
		`${key}:${JSON.stringify(value)}`
	);
}

async function openIndexDetailTab(page: Page, tabName: string) {
	const tab = page.getByRole('tab', { name: tabName, exact: true });
	await tab.scrollIntoViewIfNeeded();
	await tab.click();
	await expect(tab).toHaveAttribute('aria-selected', 'true');
}

test('Events tab renders forced initial load failure state instead of empty state', async ({
	page,
	seedIndex,
	testRegion
}) => {
	const indexName = `e2e-events-error-${Date.now()}`;
	await seedIndex(indexName, testRegion);

	await page.route(`**/console/indexes/${encodeURIComponent(indexName)}**`, async (route) => {
		const response = await route.fetch();
		const html = await response.text();
		if (html.includes('eventsLoadError')) {
			await route.fulfill({
				status: response.status(),
				headers: response.headers(),
				body: injectLoadError(html, 'eventsLoadError', 'Forced events endpoint failure')
			});
			return;
		}
		await route.fulfill({ response });
	});

	await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
	await openIndexDetailTab(page, 'Events');
	await expect(page.getByTestId('events-load-error-state')).toBeVisible();
	await expect(page.getByTestId('events-load-error-state')).toContainText(
		'Forced events endpoint failure'
	);
	await expect(page.getByText('No events received yet')).toHaveCount(0);
	await expect(page.getByTestId('events-retry-btn')).toBeVisible();
});
