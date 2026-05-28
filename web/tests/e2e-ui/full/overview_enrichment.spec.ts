import { test, expect } from '../../fixtures/fixtures';
import { openIndexDetailTab, openSeededIndexDetailPage } from './index_detail_helpers';

test('Overview tab seeded route exposes analytics, navigation, export, and import contracts', async ({
	page,
	seedIndex,
	testRegion
}) => {
	const indexName = await openSeededIndexDetailPage(
		page,
		seedIndex,
		testRegion,
		'e2e-overview-enrichment'
	);

	await expect(page.getByTestId('overview-analytics-summary')).toBeVisible();
	await page.getByTestId('overview-view-analytics-link').click();
	await expect(page).toHaveURL(
		new RegExp(`/console/indexes/${encodeURIComponent(indexName)}\\?tab=analytics`)
	);
	await openIndexDetailTab(page, 'Analytics', 'analytics-section', false);

	await page.goto(`/console/indexes/${encodeURIComponent(indexName)}?tab=overview`);
	const navFooter = page.getByTestId('overview-navigation');
	await navFooter.getByRole('link', { name: /configure settings/i }).click();
	await expect(page).toHaveURL(new RegExp('\\?tab=settings'));
	await openIndexDetailTab(page, 'Settings', 'settings-section', false);

	await page.goto(`/console/indexes/${encodeURIComponent(indexName)}?tab=overview`);
	await page
		.getByTestId('overview-navigation')
		.getByRole('link', { name: /manage documents/i })
		.click();
	await expect(page).toHaveURL(new RegExp('\\?tab=documents'));
	await openIndexDetailTab(page, 'Documents', 'documents-section', false);

	await page.goto(`/console/indexes/${encodeURIComponent(indexName)}?tab=overview`);
	await page.getByTestId('overview-export-btn').click();
	await expect(page.getByTestId('overview-export-btn')).toHaveText('Export Index');
	await expect(page.getByRole('alert', { name: /overview-export-import-alert/i })).toHaveCount(0);

	const uploadRequest = page.waitForRequest(
		(request) =>
			request.method() === 'POST' &&
			request.url().includes(`/console/indexes/${encodeURIComponent(indexName)}?/uploadDocuments`)
	);
	const uploadFilePayload = JSON.stringify([
		{
			objectID: `overview-import-${Date.now()}`,
			title: 'Overview import upload contract'
		}
	]);
	await page.getByLabel(/import json or csv file/i).setInputFiles({
		name: 'overview-import-contract.json',
		mimeType: 'application/json',
		buffer: Buffer.from(uploadFilePayload, 'utf-8')
	});
	await uploadRequest;
	await expect(page).toHaveURL(
		new RegExp(`/console/indexes/${encodeURIComponent(indexName)}\\?tab=overview`)
	);

	const importBanner = page
		.getByTestId('overview-data-management')
		.getByText('Documents uploaded.');
	await expect(importBanner).toBeVisible();
});
