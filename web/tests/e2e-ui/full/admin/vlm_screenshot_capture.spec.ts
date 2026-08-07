/**
 * VLM capture — admin lane (admin_customers).
 *
 * Reuses the admin storage state produced by
 * `web/tests/fixtures/admin.auth.setup.ts` (loaded automatically by the
 * `chromium:admin` project). `createUser` arranges a disposable row only for
 * the filter-empty tuple and does not replace the page's admin storage state;
 * the redirect guard still rejects any mislabeled capture.
 *
 * Each tuple's `setup` discriminator (from `vlm_capture/tuples.ts`)
 * decides whether to additionally fill the customer-search input with a
 * non-matching query before capturing, so Filter-empty lands against the
 * "No customers match the current filters." branch while Loading and
 * Success land against the resolved customer table.
 *
 * Output contract: this file owns only the `admin__*` filename prefix
 * under `tmp/screens/`. On first invocation per run it ensures the
 * directory exists and removes its own prior `admin__*` artifacts so
 * stale captures cannot bleed into Stage 6, while leaving public/auth
 * lane files alone.
 *
 * File matches `chromium:admin` via the `e2e-ui/full/admin/` directory
 * placement required by the project's `testMatch` regex.
 */

import fs from 'node:fs';
import path from 'node:path';
import type { Page } from '@playwright/test';
import { test, expect } from '../../../fixtures/fixtures';
import { assertNoCaptureRedirect } from '../vlm_capture/redirect_guard';
import {
	ADMIN_FILTER_EMPTY_QUERY,
	CAPTURE_OUTPUT_DIR,
	VIEWPORT_SIZES,
	type CaptureTuple,
	captureArtifactPath,
	captureTupleTestTitle,
	isProducibleSetup,
	tuplesForLane
} from '../vlm_capture/tuples';

test.beforeAll(() => {
	fs.mkdirSync(CAPTURE_OUTPUT_DIR, { recursive: true });
	for (const entry of fs.readdirSync(CAPTURE_OUTPUT_DIR)) {
		if (entry.startsWith('admin__') && entry.endsWith('.png')) {
			fs.unlinkSync(path.join(CAPTURE_OUTPUT_DIR, entry));
		}
	}
});

function shouldCaptureFullPage(tuple: CaptureTuple): boolean {
	return !(tuple.setup === 'admin_default' && tuple.viewport === 'desktop');
}

async function arrangeSeededFilterEmptyState(page: Page, customerName: string): Promise<void> {
	const tableBody = page.getByTestId('customers-table-body');
	await expect(tableBody).toBeVisible();
	await expect(tableBody.getByText(customerName, { exact: true })).toBeVisible();

	await page.getByTestId('customer-search').fill(ADMIN_FILTER_EMPTY_QUERY);
	await expect(page.getByText('No customers match the current filters.')).toBeVisible();
}

for (const tuple of tuplesForLane('admin')) {
	test(`admin capture: ${captureTupleTestTitle(tuple)}`, async ({ page, createUser }) => {
		test.skip(
			!isProducibleSetup(tuple.setup),
			`tuple setup ${tuple.setup}: see vlm_capture/tuples.ts for the gap rationale.`
		);

		let customerName = '';
		if (tuple.setup === 'admin_filter_no_match') {
			const seed = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
			customerName = `Admin VLM Seed ${seed}`;
			await createUser(`admin-vlm-${seed}@e2e.griddle.test`, 'TestPassword123!', customerName);
		}

		await page.setViewportSize(VIEWPORT_SIZES[tuple.viewport]);
		await page.goto(tuple.path);
		await assertNoCaptureRedirect(page, tuple.path);

		if (tuple.setup === 'admin_filter_no_match') {
			// Wait for the table or the dataset-empty branch to settle so the
			// filter narrows a known-non-empty list. If the dataset is empty
			// the page already shows "No customers found." and the filter
			// branch never activates — fail loudly so the capture isn't
			// mislabeled.
			await arrangeSeededFilterEmptyState(page, customerName);
		}

		const artifactPath = captureArtifactPath(tuple);
		await page.screenshot({ path: artifactPath, fullPage: shouldCaptureFullPage(tuple) });
		expect(fs.existsSync(artifactPath)).toBe(true);
	});
}
