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

test('Security Sources tab renders forced load error state and retry affordance', async ({
	page,
	seedIndex,
	testRegion
}) => {
	const indexName = `e2e-security-error-${Date.now()}`;
	await seedIndex(indexName, testRegion);

	let injected = 0;
	await page.route(`**/console/indexes/${encodeURIComponent(indexName)}**`, async (route) => {
		const response = await route.fetch();
		const html = await response.text();
		if (injected === 0 && html.includes('securitySourcesLoadError')) {
			injected += 1;
			await route.fulfill({
				status: response.status(),
				headers: response.headers(),
				body: injectLoadError(html, 'securitySourcesLoadError', 'Forced security sources failure')
			});
			return;
		}
		await route.fulfill({ response });
	});

	await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
	await openIndexDetailTab(page, 'Security Sources');
	await expect(page.getByTestId('security-sources-error-state')).toBeVisible();
	await expect(page.getByTestId('security-sources-error-state')).toContainText(
		'Forced security sources failure'
	);
	await expect(page.getByTestId('security-sources-retry-btn')).toBeVisible();
	await page.getByTestId('security-sources-retry-btn').click();
	await expect(page.getByText('No security sources configured')).toBeVisible();
});
