import type { Page } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';

function replaceSerializedMetricsPayload(
	html: string,
	metricsLiteral: string,
	metricsErrorLiteral = 'null'
): string {
	return html
		.replace(/metrics:\{[\s\S]*?fetched_at:"[^"]*"\}/, `metrics:${metricsLiteral}`)
		.replace(/metricsError:(null|\{[\s\S]*?\})/, `metricsError:${metricsErrorLiteral}`);
}

async function openMetricsTab(page: Page, indexName: string): Promise<void> {
	await page.goto(`/console/indexes/${encodeURIComponent(indexName)}?tab=metrics`);
	const tab = page.getByRole('tab', { name: 'Metrics', exact: true });
	await expect(tab).toHaveAttribute('aria-selected', 'true');
}

test('Metrics tab uses query-param selection and renders the W2A payload contract', async ({
	page,
	seedIndex,
	testRegion
}) => {
	const indexName = `e2e-metrics-${Date.now()}`;
	await seedIndex(indexName, testRegion);

	await page.route(`**/console/indexes/${encodeURIComponent(indexName)}**`, async (route) => {
		const response = await route.fetch();
		const html = await response.text();
		await route.fulfill({
			status: response.status(),
			headers: response.headers(),
			body: replaceSerializedMetricsPayload(
				html,
				`{index:"${indexName}",documents_count:1234,storage_bytes:2048,search_requests_total:5678,write_operations_total:90,fetched_at:"2026-03-01T10:00:00Z"}`
			)
		});
	});

	await page.clock.install();
	await page.clock.setFixedTime(new Date('2026-03-01T10:01:00Z'));
	await openMetricsTab(page, indexName);

	const metricsPanel = page.getByTestId('metrics-tab-panel');
	await expect(metricsPanel).toBeVisible();
	await expect(metricsPanel.getByTestId('metrics-kpi-documents')).toContainText('1,234');
	await expect(metricsPanel.getByTestId('metrics-kpi-storage')).toContainText('2.0 KB');
	await expect(metricsPanel.getByTestId('metrics-kpi-search-requests')).toContainText('5,678');
	await expect(metricsPanel.getByTestId('metrics-kpi-write-operations')).toContainText('90');
	await expect(metricsPanel.getByTestId('metrics-fetched-at')).toContainText('Last fetched 1m ago');
	await expect(page.getByTestId('metrics-refresh-btn')).toBeVisible();
});

test('Metrics tab isolates metrics failures to a tab-local alert', async ({
	page,
	seedIndex,
	testRegion
}) => {
	const indexName = `e2e-metrics-error-${Date.now()}`;
	await seedIndex(indexName, testRegion);

	await page.route(`**/console/indexes/${encodeURIComponent(indexName)}**`, async (route) => {
		const response = await route.fetch();
		const html = await response.text();
		await route.fulfill({
			status: response.status(),
			headers: response.headers(),
			body: replaceSerializedMetricsPayload(
				html,
				'null',
				'{code:503,message:"Metrics service unavailable"}'
			)
		});
	});

	await openMetricsTab(page, indexName);

	const metricsPanel = page.getByTestId('metrics-tab-panel');
	await expect(metricsPanel).toBeVisible();
	await expect(metricsPanel.getByRole('alert')).toContainText('Metrics service unavailable');
	await expect(page.getByRole('heading', { name: indexName })).toBeVisible();
	await expect(page.getByRole('alert')).toHaveCount(1);
});
