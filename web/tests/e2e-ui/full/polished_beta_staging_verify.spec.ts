import type { Locator, Page } from '@playwright/test';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test, expect, type CreatedFixtureUser } from '../../fixtures/fixtures';
import { seedSearchableIndexForCustomer } from '../../fixtures/searchable-index';
import { resolveFixtureEnv } from '../../../playwright.config.contract';
import {
	getSearchPreviewPaginationControls,
	SEARCH_PANEL_TEST_ID,
	SEARCH_TAB_LABEL,
	SEARCH_TAB_QUERY_VALUE,
	submitSearchPreviewQuery,
	waitForSearchPreviewHitsToContain,
	waitForSearchPreviewReady,
	waitForSearchPreviewTotalHits
} from '../../fixtures/search-preview-helpers';

// Shared-login lane classification (Stage 1 — precedes any fixture change).
//
// Every authenticated lane below is arranged through `arrangeTrackedCustomerSession`
// (see `web/tests/fixtures/fixtures.ts`), which is the current login/session owner.
// The empty `test.use({ storageState })` override below discards the project-level
// `setup:user` session so each lane re-provisions a fresh tracked customer in
// `beforeEach`. Classification of whether each lane could instead SHARE one tracked
// session (the Stage 2 seam) versus needing an isolated arrangement:
//
//   Lane A — SHAREABLE. Only lane-scoped mutation is index + rule creation via
//            `seedCustomerIndex` / `seedRules` against a per-lane unique index name.
//   Lane B — SHAREABLE. Only lane-scoped mutation is index creation via
//            `seedCustomerIndex` (no rules); asserts routing/slug behavior.
//   Lanes C-F — SHAREABLE ONLY IF Stage 2 preserves per-lane unique index names and
//            keeps cleanup/ownership for `seedSearchableIndexForCustomer(...)`. Each
//            seeds its own `uniqueName(...)` index, so the risk is leaked/accumulated
//            index state across a shared session, not the identity of the customer.
//   Lane G — REQUIRES NO logged-in customer. It is a static follow-up-file contract
//            (`existsSync`/`readFileSync` only) and lives outside the authenticated
//            describe; it neither logs in nor mutates customer state.
//
// No lane currently requires an isolated arrangement for irreversible customer-state
// mutation — every mutation is lane-scoped index/rule seeding under a unique name.
// The main Stage 2 risk is therefore leaked/accumulated index state for Lanes C-F,
// NOT auth identity coupling. When Stage 2 removes the override, reuse the existing
// fixture layer (`arrangeTrackedCustomerSessionForPage`, `arrangeTrackedCustomerSession`,
// `loginAsUser`, and `setAuthCookieForToken`) as the shared-login seam rather than
// introducing a parallel login helper inside this spec.
const STAGING_VERIFY_TIMEOUT_MS = 240_000;
const specDir = dirname(fileURLToPath(import.meta.url));
const MERCH_MODE_PIN_FOLLOWUP_PATH = resolve(
	specDir,
	'../../../..',
	'chats/icg/jun09_pm_merch_mode_pin_staging_followup.md'
);

type SeedCustomerIndexFn = (
	customer: CreatedFixtureUser,
	name: string,
	region?: string
) => Promise<void>;

type SeedRulePayload = { objectID: string } & Record<string, unknown>;
type SeedRulesFn = (indexName: string, rules: SeedRulePayload[]) => Promise<void>;
type SearchRulesFn = (
	indexName: string,
	query?: string,
	page?: number,
	hitsPerPage?: number
) => Promise<{ hits: SeedRulePayload[]; nbHits: number }>;

type SearchDocument = {
	objectID: string;
	title: string;
	subtitle: string;
	body: string;
	image_url: string;
	tags: string[];
	category: string;
};

function uniqueName(prefix: string): string {
	return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

function buildSearchDocuments(prefix: string, count: number): SearchDocument[] {
	return Array.from({ length: count }, (_, index) => {
		const pageNumber = index + 1;
		return {
			objectID: `${prefix}-doc-${pageNumber}`,
			title: `Polished Beta Pancake ${pageNumber}`,
			subtitle: `Staging verification card ${pageNumber}`,
			body: `polished beta staging verification searchable document ${pageNumber}`,
			image_url: `https://placehold.co/120x80/png?text=PB${pageNumber}`,
			tags: ['polished-beta', pageNumber % 2 === 0 ? 'even' : 'odd'],
			category: 'staging_verify'
		};
	});
}

async function openMerchandisingHub(page: Page): Promise<Locator> {
	const section = page.getByTestId('merchandising-section');
	if ((await section.count()) > 0 && (await section.first().isVisible())) {
		return section;
	}
	await page.getByRole('tab', { name: 'Merchandising', exact: true }).click();
	await expect(section).toBeVisible({ timeout: 15_000 });
	return section;
}

async function seedIndexAndOpen(
	page: Page,
	seedCustomerIndex: SeedCustomerIndexFn,
	customer: CreatedFixtureUser,
	testRegion: string,
	prefix: string,
	tab = ''
): Promise<string> {
	const indexName = uniqueName(prefix);
	await seedCustomerIndex(customer, indexName, testRegion);
	const query = tab ? `?tab=${tab}` : '';
	await page.goto(`/console/indexes/${encodeURIComponent(indexName)}${query}`);
	await expect(page.getByRole('heading', { name: indexName })).toBeVisible({ timeout: 30_000 });
	return indexName;
}

async function openSearchWithDocuments(params: {
	page: Page;
	customer: CreatedFixtureUser;
	testRegion: string;
	prefix: string;
	documentCount: number;
	query: string;
}): Promise<{ indexName: string; documents: SearchDocument[] }> {
	const { page, customer, testRegion, prefix, documentCount, query } = params;
	const indexName = uniqueName(prefix);
	const documents = buildSearchDocuments(indexName, documentCount);
	const env = resolveFixtureEnv(process.env);
	await seedSearchableIndexForCustomer({
		apiUrl: env.apiUrl,
		adminKey: env.adminKey,
		customerId: customer.customerId,
		token: customer.token,
		name: indexName,
		region: testRegion,
		query,
		expectedHitText: 'Polished Beta Pancake',
		documents
	});
	await page.goto(
		`/console/indexes/${encodeURIComponent(indexName)}?tab=${SEARCH_TAB_QUERY_VALUE}`
	);
	await expect(page.getByRole('heading', { name: indexName })).toBeVisible({ timeout: 30_000 });
	await page.getByRole('tab', { name: SEARCH_TAB_LABEL }).click();
	await expect(page.getByTestId(SEARCH_PANEL_TEST_ID)).toBeVisible({ timeout: 15_000 });
	const currentUrl = new URL(page.url());
	expect(currentUrl.searchParams.get('tab')).toBe(SEARCH_TAB_QUERY_VALUE);
	await waitForSearchPreviewReady(page);
	await submitSearchPreviewQuery(page, query);
	await waitForSearchPreviewHitsToContain(page, 'Polished Beta Pancake', 60_000);
	return { indexName, documents };
}

async function expectLoadedDocumentImage(page: Page): Promise<void> {
	const image = page.getByTestId('document-card-image').first();
	await expect(image).toBeVisible({ timeout: 30_000 });
	await expect
		.poll(
			() =>
				image.evaluate((node) => {
					const img = node as HTMLImageElement;
					return { complete: img.complete, naturalWidth: img.naturalWidth };
				}),
			{ timeout: 30_000 }
		)
		.toEqual({ complete: true, naturalWidth: expect.any(Number) });
	const naturalWidth = await image.evaluate((node) => (node as HTMLImageElement).naturalWidth);
	expect(naturalWidth).toBeGreaterThan(0);
}

async function clickLastVisiblePage(page: Page): Promise<void> {
	const pageButtons = page.getByTestId('search-preview-results').getByRole('button', {
		name: /^Page \d+$/
	});
	const count = await pageButtons.count();
	expect(count).toBeGreaterThan(1);
	await pageButtons.nth(count - 1).click();
	await expect(page.getByTestId('search-preview-results-skeleton')).toHaveCount(0, {
		timeout: 30_000
	});
}

test.describe('Polished beta deployed staging verification', () => {
	test.describe.configure({ timeout: STAGING_VERIFY_TIMEOUT_MS, mode: 'serial' });

	let activeCustomer: CreatedFixtureUser;

	test.beforeEach(
		async ({
			page,
			arrangeSharedTrackedCustomerSession,
			ensureLocalSharedVmInventory,
			testRegion
		}) => {
			await ensureLocalSharedVmInventory(testRegion);
			activeCustomer = await arrangeSharedTrackedCustomerSession.arrange(page, {
				emailPrefix: 'e2e-staging-verify'
			});
		}
	);

	test('Lane A - Merchandising hub renders rules and no legacy search canvas @staging_verify', async ({
		page,
		seedCustomerIndex,
		seedRules,
		searchRules,
		testRegion
	}) => {
		const indexName = await seedIndexAndOpen(
			page,
			seedCustomerIndex,
			activeCustomer,
			testRegion,
			'e2e-stage-merch',
			'merchandising'
		);
		const ruleObjectID = uniqueName('stage-draft-rule');
		await seedRules(indexName, [
			{
				objectID: ruleObjectID,
				description: 'Draft staging verification rule',
				enabled: false,
				conditions: [{ pattern: 'Polished Beta', anchoring: 'contains' }],
				consequence: { promote: [{ objectID: 'doc-promoted', position: 1 }] }
			}
		]);
		await page.reload();
		const section = await openMerchandisingHub(page);
		await expect(section.getByRole('heading', { name: 'Merchandising hub' })).toBeVisible();
		await expect(
			section.getByText('Merchandising performance stats are not available yet.')
		).toBeVisible();
		await expect(section.getByRole('button', { name: /^Pin\b/i })).toHaveCount(0);
		await expect(section.getByRole('button', { name: /Save as Rule/i })).toHaveCount(0);
		const row = section.getByTestId(`merchandising-rule-row-${ruleObjectID}`);
		await expect(row).toContainText('When query contains "Polished Beta", pin 1 result');
		await expect(row).toContainText('Draft');
		const seededRules = await searchRules(indexName, '', 0, 10);
		expect(seededRules.hits.some((rule) => rule.objectID === ruleObjectID)).toBe(true);
	});

	test('Lane B - Rules tab slug lands on merchandising hub @staging_verify', async ({
		page,
		seedCustomerIndex,
		testRegion
	}) => {
		const indexName = await seedIndexAndOpen(
			page,
			seedCustomerIndex,
			activeCustomer,
			testRegion,
			'e2e-stage-rules-slug'
		);
		await expect(page.getByTestId('index-tabs-strip')).toBeVisible();
		await expect(page.getByRole('tab', { name: 'Rules', exact: true })).toHaveCount(0);
		await page.goto(`/console/indexes/${encodeURIComponent(indexName)}?tab=rules`);
		await expect(page.getByRole('heading', { name: indexName })).toBeVisible({ timeout: 15_000 });
		await expect(page.getByRole('tab', { name: 'Rules', exact: true })).toHaveCount(0);
		await expect(page.getByTestId('merchandising-section')).toBeVisible({ timeout: 15_000 });
	});

	test('Lane C - Unified Search renders image-backed document cards @staging_verify', async ({
		page,
		testRegion
	}) => {
		await openSearchWithDocuments({
			page,
			customer: activeCustomer,
			testRegion,
			prefix: 'e2e-stage-image-cards',
			documentCount: 6,
			query: 'Polished Beta'
		});
		await expect(page.getByTestId('document-card-title').first()).toContainText(
			'Polished Beta Pancake'
		);
		await expect(page.getByTestId('document-card-subtitle').first()).toContainText(
			'Staging verification card'
		);
		await expect(page.getByTestId('document-card-tag').first()).toContainText('polished-beta');
		await expectLoadedDocumentImage(page);
	});

	test('Lane D - Search keeps its only preference inline @staging_verify', async ({
		page,
		testRegion
	}) => {
		await openSearchWithDocuments({
			page,
			customer: activeCustomer,
			testRegion,
			prefix: 'e2e-stage-display-prefs',
			documentCount: 4,
			query: 'Polished Beta'
		});
		await expect(page.getByRole('button', { name: 'Display preferences' })).toHaveCount(0);
		const checkbox = page.getByLabel('Search as you type');
		await expect(checkbox).not.toBeChecked();
		await checkbox.click();
		await expect(checkbox).toBeChecked();
	});

	test('Lane E - Query metrics report hit count and processing time @staging_verify', async ({
		page,
		testRegion
	}) => {
		await openSearchWithDocuments({
			page,
			customer: activeCustomer,
			testRegion,
			prefix: 'e2e-stage-query-metrics',
			documentCount: 5,
			query: 'Polished Beta'
		});
		const metrics = page.getByTestId('search-preview-results').getByText(/\d+\s+hits in \d+ms/i);
		await expect(metrics).toBeVisible();
		const metricsText = (await metrics.textContent()) ?? '';
		const match = metricsText.match(/(\d+)\s+hits in (\d+)ms/i);
		expect(match).not.toBeNull();
		expect(Number(match?.[1])).toBeGreaterThanOrEqual(5);
		expect(Number(match?.[2])).toBeGreaterThanOrEqual(0);
	});

	test('Lane F - Numbered pagination reaches first second and last pages @staging_verify', async ({
		page,
		testRegion
	}) => {
		await openSearchWithDocuments({
			page,
			customer: activeCustomer,
			testRegion,
			prefix: 'e2e-stage-pagination',
			documentCount: 45,
			query: 'Polished Beta'
		});
		// Total-pages checks are meaningless until indexing catches up to the full seeded set.
		await waitForSearchPreviewTotalHits(page, 45, 90_000);
		const { previous, next } = getSearchPreviewPaginationControls(page);
		await expect(previous).toBeDisabled();
		await expect(next).toBeEnabled();
		await expect(page.getByRole('button', { name: 'Page 1' })).toHaveAttribute(
			'aria-current',
			'page'
		);
		await page.getByRole('button', { name: 'Page 2' }).click();
		await expect(page.getByTestId('search-preview-results-skeleton')).toHaveCount(0, {
			timeout: 30_000
		});
		await expect(page.getByRole('button', { name: 'Page 2' })).toHaveAttribute(
			'aria-current',
			'page'
		);
		await expect(previous).toBeEnabled();
		await clickLastVisiblePage(page);
		await expect(next).toBeDisabled();
		await expect(previous).toBeEnabled();
	});

	test('auth-call budget stays within shared-session ceiling', async ({
		arrangeSharedTrackedCustomerSession
	}) => {
		const authCallTotals = arrangeSharedTrackedCustomerSession.getAuthCallTotals();
		const authCallCount = arrangeSharedTrackedCustomerSession.getAuthCallCount();
		expect(
			authCallCount,
			`Shared-session auth-call budget exceeded: observed ${authCallCount} POST requests ` +
				`(/auth/login=${authCallTotals.login}, /auth/register=${authCallTotals.register}) ` +
				`across polished-beta staging lanes ` +
				`(budget = 1 register + 1 login + up to 2 re-verify/refresh reapplications = <=4).`
		).toBeLessThanOrEqual(4);
	});
});

test('Lane G - Merch mode pin controls are deferred to follow-up contract @staging_verify', async () => {
	expect(existsSync(MERCH_MODE_PIN_FOLLOWUP_PATH)).toBe(true);
	const followup = readFileSync(MERCH_MODE_PIN_FOLLOWUP_PATH, 'utf8');
	expect(followup).toContain('Lane G');
	expect(followup).toContain('no current `merchandising mode`, `merchMode`, or `@merch_mode_pin`');
	expect(followup).toContain('stable selectors');
});
