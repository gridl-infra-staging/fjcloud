/**
 * VLM capture — public lane (terms / privacy / dpa).
 *
 * Routes here render without authentication, so each test uses a bare
 * page context (storage state cleared) to mirror an unauthenticated
 * visitor. Tuples come from `vlm_capture/tuples.ts` — never inline a
 * tuple list here.
 *
 * Output contract: this file owns only the `public__*` filename prefix
 * under `tmp/screens/`. On first invocation per run it ensures the
 * directory exists and removes its own prior `public__*` artifacts so
 * stale captures cannot bleed into Stage 6, while leaving auth/admin
 * lane files alone (those run as separate Playwright projects in
 * parallel).
 *
 * File matches `chromium:public` via the `public-` filename prefix
 * required by the project's `testMatch` regex in
 * `playwright.config.contract.ts`.
 */

import fs from 'node:fs';
import path from 'node:path';
import { test, expect } from '../../fixtures/fixtures';
import { assertNoCaptureRedirect } from './vlm_capture/redirect_guard';
import {
	CAPTURE_OUTPUT_DIR,
	VIEWPORT_SIZES,
	captureArtifactPath,
	captureTupleTestTitle,
	tuplesForLane
} from './vlm_capture/tuples';

// Public routes do not need auth cookies; clear any default storage state.
test.use({ storageState: { cookies: [], origins: [] } });

test.beforeAll(() => {
	fs.mkdirSync(CAPTURE_OUTPUT_DIR, { recursive: true });
	for (const entry of fs.readdirSync(CAPTURE_OUTPUT_DIR)) {
		if (entry.startsWith('public__') && entry.endsWith('.png')) {
			fs.unlinkSync(path.join(CAPTURE_OUTPUT_DIR, entry));
		}
	}
});

for (const tuple of tuplesForLane('public')) {
	test(`public capture: ${captureTupleTestTitle(tuple)}`, async ({ page }) => {
		await page.setViewportSize(VIEWPORT_SIZES[tuple.viewport]);
		await page.goto(tuple.path);
		await assertNoCaptureRedirect(page, tuple.path);

		const artifactPath = captureArtifactPath(tuple);
		await page.screenshot({ path: artifactPath, fullPage: true });
		expect(fs.existsSync(artifactPath)).toBe(true);
	});
}
