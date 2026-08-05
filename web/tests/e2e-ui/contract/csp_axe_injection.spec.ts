import axe from 'axe-core';
import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';
import {
	AXE_SAME_ORIGIN_PATH,
	documentCspHeaderValue,
	installSameOriginAxe
} from '../../fixtures/axe_injection';

/**
 * Hermetic contract for the accessibility scanner's loading strategy.
 *
 * This spec starts no application. Every request, including the document, is
 * fulfilled by `page.route`, so it runs in any worktree regardless of which
 * host ports a co-resident lane is holding. That matters: the defect it guards
 * was found only because a lane could not get the full stack up, and a proof
 * that needs the contended stack could not have caught it either.
 *
 * What it pins:
 *   1. The enforced production CSP really does refuse an inline `<script>`,
 *      so the same-origin indirection is load-bearing rather than decorative.
 *   2. Serving the scanner from a same-origin URL really does satisfy
 *      `script-src 'self'`, and axe actually runs afterwards.
 *
 * Assertion (1) is the negative control. Without it a weakened CSP would make
 * (2) pass for the wrong reason and this file would stop protecting anything.
 */

const CSP_CONTRACT_ORIGIN = 'http://127.0.0.1:9';

const DOCUMENT_BODY = `<!doctype html>
<html lang="en">
	<head><title>CSP axe injection contract</title></head>
	<body>
		<main><h1>CSP axe injection contract</h1></main>
	</body>
</html>`;

/**
 * Serve one document carrying the exact enforced policy the customer surface
 * ships, rendered from its production owner rather than pasted here.
 */
async function gotoCspProtectedDocument(page: Page): Promise<void> {
	await page.route(`${CSP_CONTRACT_ORIGIN}/`, (route) =>
		route.fulfill({
			status: 200,
			contentType: 'text/html; charset=utf-8',
			headers: {
				'content-security-policy': documentCspHeaderValue('production'),
				// The document surface also sets this; a script response with a
				// wrong media type would be refused for a different reason and
				// muddy what this spec proves.
				'x-content-type-options': 'nosniff'
			},
			body: DOCUMENT_BODY
		})
	);
	await page.goto(`${CSP_CONTRACT_ORIGIN}/`);
}

/** True when the axe runtime is present and callable on the current document. */
async function axeIsAvailable(page: Page): Promise<boolean> {
	return page.evaluate(
		() => typeof (window as unknown as { axe?: { run?: unknown } }).axe?.run === 'function'
	);
}

test.describe('accessibility scanner loading under the enforced CSP', () => {
	test('the enforced policy refuses an inline scanner injection', async ({ page }) => {
		await gotoCspProtectedDocument(page);

		// This is exactly what accessibility.spec.ts did before 2026-08-03.
		// Chromium may reject the injection outright or accept the element and
		// silently decline to execute it; both are CSP doing its job, and the
		// observable post-condition is the same either way.
		await page.addScriptTag({ content: axe.source }).catch(() => undefined);

		expect(
			await axeIsAvailable(page),
			'inline injection must NOT make axe available; if this passes, script-src has been weakened'
		).toBe(false);
	});

	test('a same-origin scanner URL satisfies script-src self and axe runs', async ({ page }) => {
		await gotoCspProtectedDocument(page);
		await installSameOriginAxe(page);

		expect(await axeIsAvailable(page), 'same-origin injection must make axe available').toBe(true);

		// Prove the runtime is functional, not merely defined: run the same three
		// browser-owned rules the catalog scans for and assert a real result shape
		// with a populated URL. A stub that defined window.axe would fail here.
		const result = await page.evaluate(async () => {
			const runner = (
				window as unknown as {
					axe: {
						run: (ctx: Document, opts: unknown) => Promise<{ url: string; violations: unknown[] }>;
					};
				}
			).axe;
			return runner.run(document, {
				runOnly: { type: 'rule', values: ['color-contrast', 'landmark-one-main', 'region'] }
			});
		});

		expect(Array.isArray(result.violations)).toBe(true);
		expect(result.url).toContain(CSP_CONTRACT_ORIGIN);
	});

	test('the scanner is fetched from a same-origin path, not a third-party host', async ({
		page
	}) => {
		await gotoCspProtectedDocument(page);

		const scriptRequestUrls: string[] = [];
		page.on('request', (request) => {
			if (request.resourceType() === 'script') {
				scriptRequestUrls.push(request.url());
			}
		});

		await installSameOriginAxe(page);

		// Loading axe from a CDN would also satisfy a permissive policy and would
		// pass the test above if script-src ever gained a host source. Pin the
		// origin so the scan stays offline and same-origin by construction.
		expect(scriptRequestUrls).toContain(`${CSP_CONTRACT_ORIGIN}${AXE_SAME_ORIGIN_PATH}`);
	});
});
