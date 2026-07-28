import type { Locator } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';
import {
	COMMUNITY_DISCUSSIONS_URL,
	COMMUNITY_IDEAS_URL,
	COMMUNITY_QA_URL,
	DOCUMENTATION_SOURCE_URL,
	ENGINE_ISSUES_URL,
	READER_DOCS_URL,
	SECURITY_POLICY_URL,
	SUPPORT_EMAIL
} from '../../../src/lib/format';

function assertCloudSupportMailto(
	href: string | null,
	route: string,
	startedAtMs: number,
	readAtMs: number
) {
	expect(href).not.toBeNull();
	const parsed = new URL(href ?? '');
	expect(parsed.protocol).toBe('mailto:');
	expect(decodeURIComponent(parsed.pathname)).toBe(SUPPORT_EMAIL);
	expect(parsed.searchParams.get('subject')).toBe('Flapjack Cloud support request');

	const body = parsed.searchParams.get('body') ?? '';
	expect(body).toContain(`Route: ${route}`);
	const timestampMatch = body.match(/Timestamp: (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z)/);
	expect(timestampMatch).not.toBeNull();
	const timestampMs = Date.parse(timestampMatch?.[1] ?? '');
	expect(Number.isNaN(timestampMs)).toBe(false);
	expect(timestampMs).toBeGreaterThanOrEqual(startedAtMs);
	expect(timestampMs).toBeLessThanOrEqual(readAtMs);
}

async function assertSupportRouting(container: Locator, route: string) {
	const supportAffordance = container.getByRole('button', {
		name: 'Report a problem or request a feature'
	});
	await expect(supportAffordance).toHaveCount(1);
	await expect(supportAffordance).toBeVisible();
	await expect(container.getByRole('link', { name: 'Support', exact: true })).toHaveCount(0);

	const cloudSupport = container.getByRole('link', {
		name: 'Email support for cloud console, API, billing, account, invoice, index, or data issues'
	});

	// The disclosure is the discoverability contract: destinations must be absent until the
	// customer activates the affordance, and present after. Asserting both sides keeps this spec
	// red if the control regresses to always-expanded or to an inert button with no handler.
	await expect(supportAffordance).toHaveAttribute('aria-expanded', 'false');
	await expect(cloudSupport).toHaveCount(0);
	const disclosureStartedAtMs = Date.now();
	await supportAffordance.click();
	await expect(supportAffordance).toHaveAttribute('aria-expanded', 'true');

	const cloudHref = await cloudSupport.getAttribute('href');
	assertCloudSupportMailto(cloudHref, route, disclosureStartedAtMs, Date.now());

	await expect(container.getByRole('link', { name: 'Share an idea' })).toHaveAttribute(
		'href',
		COMMUNITY_IDEAS_URL
	);
	await expect(container.getByRole('link', { name: 'Ask a question' })).toHaveAttribute(
		'href',
		COMMUNITY_QA_URL
	);
	await expect(container.getByRole('link', { name: 'Report an engine bug' })).toHaveAttribute(
		'href',
		ENGINE_ISSUES_URL
	);
	await expect(
		container.getByRole('link', { name: 'Propose a documentation correction' })
	).toHaveAttribute('href', DOCUMENTATION_SOURCE_URL);
	await expect(
		container.getByRole('link', { name: 'Read private security reporting instructions' })
	).toHaveAttribute('href', SECURITY_POLICY_URL);
	await expect(container).toContainText(
		'Do not include account, invoice, index, or customer-data details in public GitHub posts.'
	);
	await expect(container).toContainText(
		'Security vulnerabilities use the private reporting policy, not public trackers.'
	);
}

test.describe('Support routing discoverability', () => {
	// Untagged deliberately: the P0-coverage tag is owned by
	// docs/audits/ui_test_coverage_p0_ledger.md and its occurrence count is a tracked launch gate.
	// No ledger row covers support routing, so tagging this scenario would inflate that count
	// without closing a row. (The literal tag is omitted here because the gate greps raw text.)
	test('public footer, console Help, and error boundary expose the support contract', async ({
		page
	}) => {
		await page.goto('/pricing');
		const footer = page.getByRole('contentinfo');
		await expect(footer.getByRole('link', { name: 'Docs' })).toHaveAttribute(
			'href',
			READER_DOCS_URL
		);
		await expect(footer.getByRole('link', { name: 'Community' })).toHaveAttribute(
			'href',
			COMMUNITY_DISCUSSIONS_URL
		);

		await page.setViewportSize({ width: 1280, height: 900 });
		await page.goto('/console/indexes');
		const desktopNav = page.getByTestId('dashboard-nav-desktop');
		await expect(desktopNav).toBeVisible();
		await assertSupportRouting(desktopNav, '/console/indexes');

		await page.setViewportSize({ width: 390, height: 844 });
		await page.goto('/console/indexes');
		const drawer = page.getByTestId('dashboard-nav-mobile-drawer');
		await expect(drawer).toHaveAttribute('data-nav-open', 'false');
		await expect(
			drawer.getByRole('button', { name: 'Report a problem or request a feature' })
		).toHaveCount(0);
		await page.getByTestId('dashboard-mobile-nav-trigger').click();
		await expect(drawer).toHaveAttribute('data-nav-open', 'true');
		await assertSupportRouting(drawer, '/console/indexes');

		// Rendering of the support-reference block is owned by full/public-pages.spec.ts (public
		// boundary) and full/console.spec.ts (console boundary). The fact owned here is the one
		// neither holds: the mailto payload carries the same reference the customer can read.
		await page.goto('/missing-support-routing-page');
		const supportReferenceText = await page
			.getByRole('main')
			.getByText(/^web-[a-f0-9]{12}$/)
			.textContent();
		expect(supportReferenceText).not.toBeNull();
		const supportHref = await page.getByRole('link', { name: SUPPORT_EMAIL }).getAttribute('href');
		expect(supportHref).not.toBeNull();
		expect(supportHref?.startsWith(`mailto:${SUPPORT_EMAIL}`)).toBe(true);
		expect(supportHref).toContain(supportReferenceText ?? '');
	});
});
