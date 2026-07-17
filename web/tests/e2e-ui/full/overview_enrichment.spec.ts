import { mkdir, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import type { Download, Page } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';
import {
	openIndexDetailTab,
	openSeededIndexDetailPage,
	readDownloadText
} from './index_detail_helpers';

type ProbeVerdicts = {
	export_filename_verdict: boolean;
	export_payload_verdict: boolean;
	import_banner_verdict: boolean;
};

async function assertOverviewDeepLinkContracts(page: Page, indexName: string) {
	await expect(page.getByTestId('overview-analytics-summary')).toBeVisible();
	await page.getByTestId('overview-view-analytics-link').click();
	await expect(page).toHaveURL(
		new RegExp(`/console/indexes/${encodeURIComponent(indexName)}\\?tab=analytics`)
	);
	await expect(page.getByTestId('tab-analytics')).toHaveAttribute('aria-selected', 'true');
	await expect(page.getByTestId('analytics-section')).toBeVisible();
	await openIndexDetailTab(page, 'Analytics', 'analytics-section', false);

	await page.goto(`/console/indexes/${encodeURIComponent(indexName)}?tab=overview`);
	await expect(page.getByTestId('overview-navigation')).toHaveCount(0);
}

async function importOverviewDocumentAndRefresh(page: Page, indexName: string): Promise<string> {
	await page.goto(`/console/indexes/${encodeURIComponent(indexName)}?tab=overview`);
	const importedObjectId = `overview-import-${Date.now()}`;
	const uploadRequest = page.waitForRequest(
		(request) =>
			request.method() === 'POST' &&
			request.url().includes(`/console/indexes/${encodeURIComponent(indexName)}?/uploadDocuments`)
	);
	const uploadFilePayload = JSON.stringify([
		{
			objectID: importedObjectId,
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

	const importBanner = page.getByTestId('overview-import-success-banner');
	await expect(importBanner).toContainText('Imported 1 document. Refresh page to see them');
	await expect(page.getByTestId('overview-data-management')).not.toContainText(
		'Documents uploaded.'
	);
	const importBannerAboveStats = await page.evaluate(() => {
		const banner = document.querySelector('[data-testid="overview-import-success-banner"]');
		const stats = document.querySelector('[data-testid="stats-section"]');
		if (!banner || !stats) return false;
		return Boolean(banner.compareDocumentPosition(stats) & Node.DOCUMENT_POSITION_FOLLOWING);
	});
	expect(importBannerAboveStats).toBe(true);

	const refreshRevalidationResponsePromise = page.waitForResponse((response) => {
		if (response.request().method() !== 'GET') return false;
		const url = response.url();
		return (
			url.includes(`/console/indexes/${encodeURIComponent(indexName)}/__data.json`) &&
			url.includes('x-sveltekit-invalidated=') &&
			url.includes('tab=overview')
		);
	});
	await importBanner.getByRole('button', { name: 'Refresh' }).click();
	const refreshRevalidationResponse = await refreshRevalidationResponsePromise;
	expect(refreshRevalidationResponse.ok()).toBe(true);
	await expect(page.getByTestId('overview-import-success-banner')).toHaveCount(0);
	await expect(page).toHaveURL(
		new RegExp(`/console/indexes/${encodeURIComponent(indexName)}\\?tab=overview`)
	);

	return importedObjectId;
}

async function captureOverviewExportDownload(page: Page): Promise<Download> {
	const downloadPromise = page.waitForEvent('download');
	await page.getByTestId('overview-export-btn').click();
	return await downloadPromise;
}

async function assertOverviewExportFilename(
	exportDownload: Download,
	indexName: string
): Promise<void> {
	const expectedDayStamp = new Date().toISOString().slice(0, 10).replace(/-/g, '');
	await expect(exportDownload.suggestedFilename()).toBe(
		`${indexName}-export-${expectedDayStamp}.json`
	);
}

async function readOverviewExportPayload(
	exportDownload: Download
): Promise<Array<Record<string, unknown>>> {
	const exportPayload = JSON.parse(await readDownloadText(exportDownload)) as Array<
		Record<string, unknown>
	>;
	expect(Array.isArray(exportPayload)).toBe(true);
	return exportPayload;
}

async function persistProbeVerdicts(
	probeVerdictPath: string,
	probeVerdicts: ProbeVerdicts
): Promise<void> {
	if (probeVerdictPath.length === 0) return;
	await mkdir(dirname(probeVerdictPath), { recursive: true });
	await writeFile(probeVerdictPath, `${JSON.stringify(probeVerdicts, null, 2)}\n`, 'utf-8');
}

test('Overview export shows shared success toast while preserving filename and payload contracts', async ({
	page,
	seedIndex,
	testRegion
}) => {
	const probeVerdictPath = process.env.OVERVIEW_EXPORT_PROBE_VERDICT_PATH?.trim() ?? '';
	const probeVerdicts = {
		export_filename_verdict: false,
		export_payload_verdict: false,
		import_banner_verdict: false
	};

	try {
		const indexName = await openSeededIndexDetailPage(
			page,
			seedIndex,
			testRegion,
			'e2e-overview-enrichment'
		);

		await assertOverviewDeepLinkContracts(page, indexName);
		const importedObjectId = await importOverviewDocumentAndRefresh(page, indexName);
		probeVerdicts.import_banner_verdict = true;

		const exportDownload = await captureOverviewExportDownload(page);
		await expect(page.getByText(/^Exported \d+ documents?\.$/)).toBeVisible({ timeout: 10_000 });
		await assertOverviewExportFilename(exportDownload, indexName);
		probeVerdicts.export_filename_verdict = true;

		const exportPayload = await readOverviewExportPayload(exportDownload);
		expect(
			exportPayload.some(
				(record) => typeof record.objectID === 'string' && record.objectID === importedObjectId
			)
		).toBe(true);
		const exportedDocumentCount = exportPayload.length;
		const exportedLabel = `Exported ${exportedDocumentCount} document${exportedDocumentCount === 1 ? '' : 's'}`;
		await expect(page.getByTestId('overview-data-management').getByText(exportedLabel)).toHaveCount(
			0
		);
		probeVerdicts.export_payload_verdict = true;
	} finally {
		await persistProbeVerdicts(probeVerdictPath, probeVerdicts);
	}
});
