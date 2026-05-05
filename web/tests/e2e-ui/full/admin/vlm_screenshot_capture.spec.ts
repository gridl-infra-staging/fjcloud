/**
 * VLM capture — admin lane (admin_customers).
 *
 * Reuses the admin storage state produced by
 * `web/tests/fixtures/admin.auth.setup.ts` (loaded automatically by the
 * `chromium:admin` project). We do NOT call `createUser`/`loginAs` here:
 * those mint regular-user tokens that would redirect away from admin
 * routes and silently produce mislabeled screenshots — exactly what the
 * `assertNoCaptureRedirect` guard exists to catch.
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
import { test, expect } from '../../../fixtures/fixtures';
import { assertNoCaptureRedirect } from '../vlm_capture/redirect_guard';
import {
	ADMIN_FILTER_EMPTY_QUERY,
	CAPTURE_OUTPUT_DIR,
	VIEWPORT_SIZES,
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

for (const tuple of tuplesForLane('admin')) {
	test(`admin capture: ${captureTupleTestTitle(tuple)}`, async ({ page }) => {
		test.skip(
			!isProducibleSetup(tuple.setup),
			`tuple setup ${tuple.setup}: see vlm_capture/tuples.ts for the gap rationale.`
		);

		await page.setViewportSize(VIEWPORT_SIZES[tuple.viewport]);
		await page.goto(tuple.path);
		await assertNoCaptureRedirect(page, tuple.path);

		if (tuple.setup === 'admin_filter_no_match') {
			// Wait for the table or the dataset-empty branch to settle so the
			// filter narrows a known-non-empty list. If the dataset is empty
			// the page already shows "No customers found." and the filter
			// branch never activates — fail loudly so the capture isn't
			// mislabeled.
			const tableBody = page.getByTestId('customers-table-body');
			await expect(tableBody).toBeVisible();

			await page.getByTestId('customer-search').fill(ADMIN_FILTER_EMPTY_QUERY);
			await expect(page.getByText('No customers match the current filters.')).toBeVisible();
		}

		const artifactPath = captureArtifactPath(tuple);
		await page.screenshot({ path: artifactPath, fullPage: true });
		expect(fs.existsSync(artifactPath)).toBe(true);
	});
}
