import type { Locator, Page } from '@playwright/test';
import { expect } from '@playwright/test';

type SearchPreviewState = 'generate' | 'unavailable' | 'pending';

export const SEARCH_PREVIEW_STATE_TIMEOUT_MS = 10_000;
export const SEARCH_PREVIEW_READY_TIMEOUT_MS = 90_000;
export const SEARCH_PREVIEW_READY_MESSAGE =
	'Waiting for Search Preview to become ready for preview-key generation';
export const INDEX_DETAIL_READY_TIMEOUT_MS = 30_000;
export const PREVIEW_SUBMIT_OUTCOME_TIMEOUT_MS = 5_000;
export const PREVIEW_SUBMIT_IN_FLIGHT_TIMEOUT_MS = 30_000;
export const PREVIEW_SUBMIT_MAX_PENDING_TIMEOUT_MS = 90_000;
const LOCAL_STACK_UNAVAILABLE_ERROR_PATTERN =
	/(?:ECONNREFUSED|EHOSTUNREACH|ENOTFOUND|Connection refused|fetch failed|Failed to fetch|network error|127\\.0\\.0\\.1|localhost)/i;

type SearchPreviewLocators = {
	generateButton: Locator;
	tierUnavailableMessage: Locator;
	provisioningMessage: Locator;
};

export function getSearchPreviewLocators(page: Page): SearchPreviewLocators {
	const section = page.getByTestId('search-preview-section');
	return {
		generateButton: section.getByRole('button', { name: /generate preview key/i }),
		tierUnavailableMessage: section.getByText(
			/Search preview is not available while the index is/i
		),
		provisioningMessage: section.getByText(
			'Endpoint not available yet. The index is still being provisioned.'
		)
	};
}

export function getSearchPreviewReadinessSurface(page: Page): {
	generateButton: Locator;
	unavailableMessage: Locator;
} {
	const { generateButton, tierUnavailableMessage, provisioningMessage } =
		getSearchPreviewLocators(page);
	return {
		generateButton,
		unavailableMessage: tierUnavailableMessage.or(provisioningMessage).first()
	};
}

async function isVisible(locator: Locator): Promise<boolean> {
	return locator.isVisible().catch(() => false);
}

async function detectSearchPreviewState(page: Page): Promise<SearchPreviewState> {
	const { generateButton, tierUnavailableMessage, provisioningMessage } =
		getSearchPreviewLocators(page);

	if (await isVisible(generateButton)) return 'generate';
	if (await isVisible(tierUnavailableMessage)) return 'unavailable';
	if (await isVisible(provisioningMessage)) return 'pending';
	return 'pending';
}

export async function waitForSearchPreviewState(page: Page): Promise<'generate' | 'unavailable'> {
	let resolvedState: 'generate' | 'unavailable' = 'unavailable';
	await expect
		.poll(
			async () => {
				const state = await detectSearchPreviewState(page);
				if (state !== 'pending') {
					resolvedState = state;
				}
				return state;
			},
			{ timeout: SEARCH_PREVIEW_STATE_TIMEOUT_MS }
		)
		.not.toBe('pending');

	return resolvedState;
}

export async function waitForSearchPreviewReady(page: Page): Promise<void> {
	await expect
		.poll(async () => detectSearchPreviewState(page), {
			timeout: SEARCH_PREVIEW_READY_TIMEOUT_MS,
			message: SEARCH_PREVIEW_READY_MESSAGE
		})
		.toBe('generate');
}

export async function gotoIndexDetailWithRetry(page: Page, indexName: string): Promise<void> {
	const path = `/console/indexes/${encodeURIComponent(indexName)}`;

	for (let attempt = 0; attempt < 5; attempt += 1) {
		await page.goto(path);
		const heading = page.getByRole('heading', { name: indexName });
		if (await heading.isVisible().catch(() => false)) {
			return;
		}
		await page.waitForTimeout(1000 * (attempt + 1));
	}

	await expect(page.getByRole('heading', { name: indexName })).toBeVisible({
		timeout: INDEX_DETAIL_READY_TIMEOUT_MS
	});
}

export async function waitForInstantSearchWidget(page: Page): Promise<void> {
	await expect(page.getByTestId('instantsearch-widget')).toBeVisible({
		timeout: SEARCH_PREVIEW_READY_TIMEOUT_MS
	});
}

type PreviewSubmitOutcome = 'widget' | 'generic' | 'transient' | 'unknown';
type SearchPreviewAnalyticsCapture = {
	payloads: unknown[];
	stop: () => void;
};

export function failRequiredE2eGate(gateName: string, failure: unknown): never {
	const message = failure instanceof Error ? failure.message : String(failure);
	throw new Error(`Stage 6 required e2e gate "${gateName}" failed: ${message}`);
}

export function isLocalStackUnavailableError(error: unknown): boolean {
	const message = error instanceof Error ? error.message : String(error);
	return LOCAL_STACK_UNAVAILABLE_ERROR_PATTERN.test(message);
}

export function failRequiredE2eGateOnLocalStackError(gateName: string, error: unknown): void {
	if (!isLocalStackUnavailableError(error)) {
		return;
	}
	failRequiredE2eGate(gateName, error);
}

function getIndexNameFromDetailPath(detailPath: string): string {
	return decodeURIComponent(
		new URL(detailPath, 'http://localhost').pathname.split('/').pop() ?? ''
	);
}

export async function waitForPreviewSubmitOutcome(
	page: Page,
	transientError: Locator,
	genericErrorPage: Locator,
	timeoutMs: number = PREVIEW_SUBMIT_OUTCOME_TIMEOUT_MS
): Promise<PreviewSubmitOutcome> {
	const startedAt = Date.now();
	while (Date.now() - startedAt < timeoutMs) {
		if (
			await page
				.getByTestId('instantsearch-widget')
				.isVisible()
				.catch(() => false)
		) {
			return 'widget';
		}

		if (await genericErrorPage.isVisible().catch(() => false)) {
			return 'generic';
		}

		if (await transientError.isVisible().catch(() => false)) {
			return 'transient';
		}

		await page.waitForTimeout(250);
	}

	return 'unknown';
}

async function waitForPreviewSubmitResolution(
	page: Page,
	transientError: Locator,
	genericErrorPage: Locator
): Promise<PreviewSubmitOutcome> {
	const startedAt = Date.now();
	let timeoutMs = PREVIEW_SUBMIT_OUTCOME_TIMEOUT_MS;

	while (Date.now() - startedAt < PREVIEW_SUBMIT_MAX_PENDING_TIMEOUT_MS) {
		const remainingMs = PREVIEW_SUBMIT_MAX_PENDING_TIMEOUT_MS - (Date.now() - startedAt);
		if (remainingMs <= 0) {
			return 'unknown';
		}

		const outcome = await waitForPreviewSubmitOutcome(
			page,
			transientError,
			genericErrorPage,
			Math.min(timeoutMs, remainingMs)
		);
		if (outcome !== 'unknown') {
			return outcome;
		}

		timeoutMs = PREVIEW_SUBMIT_IN_FLIGHT_TIMEOUT_MS;
	}

	return 'unknown';
}

export async function generatePreviewKeyAndWaitForWidget(page: Page): Promise<void> {
	const detailPath = page.url();
	const indexName = getIndexNameFromDetailPath(detailPath);
	const section = page.getByTestId('search-preview-section');
	const generateButton = section.getByRole('button', { name: /generate preview key/i });
	const transientError = section.getByText(/endpoint not ready yet|too many requests/i);
	const genericErrorPage = page
		.getByRole('heading', { name: 'Request could not be completed' })
		.or(page.getByRole('heading', { name: 'Something went wrong' }))
		.first();

	for (let attempt = 0; attempt < 6; attempt += 1) {
		await generateButton.click();
		const settledOutcome = await waitForPreviewSubmitResolution(
			page,
			transientError,
			genericErrorPage
		);

		if (settledOutcome === 'widget') {
			return;
		}

		if (settledOutcome === 'generic') {
			await gotoIndexDetailWithRetry(page, indexName);
			await page.getByRole('tab', { name: 'Search Preview' }).click();
			await waitForSearchPreviewReady(page);
			await page.waitForTimeout(1000 * (attempt + 1));
			continue;
		}

		if (settledOutcome === 'transient') {
			await page.waitForTimeout(1000 * (attempt + 1));
			continue;
		}

		// Keep single-submit semantics for unknown/pending outcomes and rely on widget
		// visibility timeout to fail the run instead of issuing duplicate submissions.
		break;
	}

	await waitForInstantSearchWidget(page);
}

export async function submitSearchPreviewQuery(page: Page, query: string): Promise<void> {
	const section = page.getByTestId('search-preview-section');
	const searchInput = section.getByRole('searchbox', { name: /search preview query/i });
	await expect(searchInput).toBeVisible({ timeout: 10_000 });
	await searchInput.click();
	await searchInput.fill(query);
	await searchInput.press('Enter');
}

export async function toggleSearchPreviewFacet(page: Page, facetLabel: string): Promise<void> {
	const section = page.getByTestId('search-preview-section');
	await section.getByLabel(facetLabel).check();
}

export async function collectVisibleSearchPreviewCardTexts(page: Page): Promise<string[]> {
	const cards = page.getByTestId('search-preview-results').locator('[data-testid="document-card"]');
	return cards.allTextContents();
}

export async function waitForSearchPreviewHitsToContain(
	page: Page,
	expectedText: string,
	timeoutMs = 30_000
): Promise<void> {
	await expect
		.poll(
			async () => {
				const cardTexts = await collectVisibleSearchPreviewCardTexts(page);
				return cardTexts.join('\n');
			},
			{
				timeout: timeoutMs,
				message: `Waiting for Search Preview hits to contain "${expectedText}"`
			}
		)
		.toContain(expectedText);
}

export async function collectVisibleSearchPreviewHighlightHtml(page: Page): Promise<string[]> {
	const highlights = page
		.getByTestId('search-preview-results')
		.locator('[data-testid^="document-card-highlight-"]');
	return highlights.evaluateAll((nodes) => nodes.map((node) => node.innerHTML));
}

export async function countSearchPreviewHits(page: Page): Promise<number> {
	const summaryText = await page
		.getByTestId('search-preview-results')
		.getByText(/hits\s+·/i)
		.textContent();
	const matchedCount = summaryText?.match(/(\d+)\s+hits\b/i);
	if (!matchedCount) {
		throw new Error(`Could not parse hit count from summary: ${summaryText ?? '<empty>'}`);
	}
	return Number.parseInt(matchedCount[1], 10);
}

export function getSearchPreviewPaginationControls(page: Page): {
	previous: Locator;
	next: Locator;
} {
	const section = page.getByTestId('search-preview-results');
	return {
		previous: section.getByRole('button', { name: 'Previous page' }),
		next: section.getByRole('button', { name: 'Next page' })
	};
}

export function startSearchPreviewAnalyticsCapture(page: Page): SearchPreviewAnalyticsCapture {
	const payloads: unknown[] = [];
	const onRequest = (request: {
		url: () => string;
		method: () => string;
		postDataJSON: () => unknown;
	}) => {
		if (request.method() !== 'POST') {
			return;
		}
		if (!request.url().includes('/1/events')) {
			return;
		}
		payloads.push(request.postDataJSON());
	};
	page.on('request', onRequest as never);
	return {
		payloads,
		stop: () => {
			page.off('request', onRequest as never);
		}
	};
}

export async function findSearchPreviewNarrowingFacet(
	page: Page,
	preFilterHitCount: number
): Promise<{ label: string; value: string; narrowedHitCount: number }> {
	const rows = page.getByTestId('search-preview-facets').locator('li');
	const rowCount = await rows.count();

	for (let index = 0; index < rowCount; index += 1) {
		const row = rows.nth(index);
		const facetLabel = await row.getByRole('checkbox').getAttribute('aria-label');
		const countText = await row.locator('span').last().textContent();
		const narrowedHitCount = Number.parseInt((countText ?? '').trim(), 10);
		if (!facetLabel || Number.isNaN(narrowedHitCount)) {
			continue;
		}
		if (narrowedHitCount > 0 && narrowedHitCount < preFilterHitCount) {
			return {
				label: facetLabel,
				value: facetLabel.split(':').slice(1).join(':'),
				narrowedHitCount
			};
		}
	}

	throw new Error(`No narrowing facet value found for pre-filter hit count ${preFilterHitCount}`);
}
