import axe from 'axe-core';
import type { Page } from '@playwright/test';
import { createDocumentCspDirectives } from '../../svelte.config.js';

/**
 * Same-origin path the axe-core runtime is served from during browser
 * accessibility scans.
 *
 * Why this exists at all: `aug02_11am_1` (merge `ac6483e82`) put a real,
 * enforced CSP on every document, and its `script-src` is
 * `'self' https://*.js.stripe.com https://js.stripe.com` with no
 * `'unsafe-inline'`. The accessibility runner used to inject the scanner with
 * `page.addScriptTag({ content: axe.source })`, which is an INLINE script and
 * is therefore refused by that policy — so the scan could not run at all.
 *
 * The fix is to make the scanner a same-origin *resource* rather than inline
 * source text. `page.route` fulfils this path from memory, so nothing is ever
 * served by the app and no production route is added; the browser only sees a
 * same-origin script URL, which `'self'` permits.
 *
 * The rejected alternative is `browserContext({ bypassCSP: true })`. That would
 * make the scan pass by not running under the policy the product actually
 * ships, which converts a real coverage gap into a green light.
 */
export const AXE_SAME_ORIGIN_PATH = '/__fjcloud_axe_core__.js';

/**
 * CSP source keywords must be single-quoted in the header; host and scheme
 * sources must not be. SvelteKit applies the same rule when it renders
 * `kit.csp.directives`, so a serializer that got this wrong would build a
 * policy the product never ships and prove nothing.
 */
const CSP_QUOTED_KEYWORDS = new Set([
	'self',
	'none',
	'unsafe-inline',
	'unsafe-eval',
	'unsafe-hashes',
	'strict-dynamic',
	'report-sample'
]);

/** Render one directive source, quoting only the CSP keywords. */
function formatCspSource(source: string): string {
	return CSP_QUOTED_KEYWORDS.has(source) ? `'${source}'` : source;
}

/**
 * Serialize a SvelteKit `kit.csp.directives` object into a
 * `Content-Security-Policy` header value.
 *
 * Test-only. Production serialization is SvelteKit's own; this exists so a
 * hermetic browser test can reproduce the shipped policy from its single
 * owner (`createDocumentCspDirectives`) instead of pasting a policy string
 * that would silently drift from it.
 */
export function formatCspHeader(directives: Record<string, readonly string[]>): string {
	return Object.entries(directives)
		.map(([directive, sources]) => `${directive} ${sources.map(formatCspSource).join(' ')}`)
		.join('; ');
}

/**
 * The exact enforced policy the customer web surface ships, rendered as a
 * header. Derived from the production owner so this cannot drift from it.
 */
export function documentCspHeaderValue(nodeEnvironment?: string): string {
	return formatCspHeader(
		createDocumentCspDirectives(nodeEnvironment) as unknown as Record<string, readonly string[]>
	);
}

/**
 * Pages that already have the axe route registered. `page.route` handlers
 * stack, so registering per navigation would attach a new handler on every
 * scanned route; the accessibility catalog scans dozens of routes through
 * three long-lived pages.
 */
const pagesServingAxe = new WeakSet<Page>();

/**
 * Make `window.axe` available on the current document under the enforced CSP.
 *
 * Call after each navigation: the route registration is idempotent per page,
 * but the script tag has to be re-added because a navigation discards the
 * previous document's globals.
 */
export async function installSameOriginAxe(page: Page): Promise<void> {
	if (!pagesServingAxe.has(page)) {
		await page.route(`**${AXE_SAME_ORIGIN_PATH}`, (route) =>
			route.fulfill({
				status: 200,
				// A wrong or missing type would be refused by X-Content-Type-Options:
				// nosniff, which the document surface also sets.
				contentType: 'text/javascript; charset=utf-8',
				body: axe.source
			})
		);
		pagesServingAxe.add(page);
	}
	await page.addScriptTag({ url: AXE_SAME_ORIGIN_PATH });
}
