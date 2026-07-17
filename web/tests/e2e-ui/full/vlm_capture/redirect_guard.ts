/**
 * Capture-time redirect guard. Fails fast when navigation lands on a
 * different route (e.g. `/login` after auth drift) so Stage 6 never
 * receives a screenshot mislabeled with the originally-requested route.
 *
 * Scoped to vlm_capture/ deliberately — `legal_page_playwright_helpers.ts`
 * owns legal-page assertions and should not absorb capture-only logic.
 */

import { expect, type Page } from '@playwright/test';

export async function assertNoCaptureRedirect(page: Page, expectedPath: string): Promise<void> {
	const currentUrl = new URL(page.url());
	expect(
		currentUrl.pathname,
		`VLM capture for ${expectedPath} landed on ${currentUrl.pathname} — auth/redirect drift would mislabel the screenshot for Stage 6`
	).toBe(expectedPath);
}
