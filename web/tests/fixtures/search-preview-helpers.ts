import type { Locator, Page } from '@playwright/test';
import { expect } from '@playwright/test';

type SearchPreviewState = 'ready' | 'unavailable' | 'pending';

export const SEARCH_TAB_LABEL = 'Search';
export const SEARCH_PANEL_TEST_ID = 'search-section';
export const SEARCH_TAB_QUERY_VALUE = 'search';
export const SEARCH_PREVIEW_STATE_TIMEOUT_MS = 10_000;
export const SEARCH_PREVIEW_READY_TIMEOUT_MS = 90_000;
export const SEARCH_PREVIEW_READY_MESSAGE = 'Waiting for authenticated Search to become ready';
export const INDEX_DETAIL_READY_TIMEOUT_MS = 30_000;
const LOCAL_STACK_UNAVAILABLE_ERROR_PATTERN =
	/(local stack unavailable|econnrefused|connect ECONNREFUSED|failed to fetch|service is unavailable|temporarily unavailable|prerequisite unavailable in local env|verify (api_url|jwt_secret)|invalid admin key|authentication session could not be established|customer login setup failed before reaching \/console|seedindex failed: 401|get \/account failed: 401)/i;

type SearchPreviewLocators = {
	widget: Locator;
	tierUnavailableMessage: Locator;
	provisioningMessage: Locator;
};

export function getSearchPreviewLocators(page: Page): SearchPreviewLocators {
	const section = page.getByTestId(SEARCH_PANEL_TEST_ID);
	return {
		widget: page.getByTestId('instantsearch-widget'),
		tierUnavailableMessage: section.getByText(/Search is not available while the index is/i),
		provisioningMessage: section.getByText(
			'Endpoint not available yet. The index is still being provisioned.'
		)
	};
}

async function isVisible(locator: Locator): Promise<boolean> {
	return locator.isVisible().catch(() => false);
}

async function detectSearchPreviewState(page: Page): Promise<SearchPreviewState> {
	const { widget, tierUnavailableMessage, provisioningMessage } = getSearchPreviewLocators(page);

	if (await isVisible(widget)) return 'ready';
	if (await isVisible(tierUnavailableMessage)) return 'unavailable';
	if (await isVisible(provisioningMessage)) return 'pending';
	return 'pending';
}

export async function waitForSearchPreviewState(page: Page): Promise<'ready' | 'unavailable'> {
	let resolvedState: 'ready' | 'unavailable' = 'unavailable';
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
		.toBe('ready');
}

export async function gotoIndexDetailWithRetry(page: Page, indexName: string): Promise<void> {
	const path = `/console/indexes/${encodeURIComponent(indexName)}`;

	for (let attempt = 0; attempt < 5; attempt += 1) {
		await page.goto(path);
		const heading = page.getByRole('heading', { name: indexName });
		if (await isVisible(heading)) {
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

type SearchPreviewAnalyticsCapture = {
	payloads: unknown[];
	stop: () => void;
};

type SearchPreviewSearchCapture = {
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

export async function submitSearchPreviewQuery(page: Page, query: string): Promise<void> {
	const section = page.getByTestId(SEARCH_PANEL_TEST_ID);
	const searchInput = section.getByRole('searchbox', { name: /search preview query/i });
	await expect(searchInput).toBeVisible({ timeout: 10_000 });
	await searchInput.click();
	await searchInput.fill(query);
	await searchInput.press('Enter');
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
				const visibleText = (await collectVisibleSearchPreviewCardTexts(page)).join('\n');
				return visibleText;
			},
			{
				timeout: timeoutMs,
				message: `Waiting for Search hits to contain "${expectedText}"`
			}
		)
		.toContain(expectedText);
}

export async function countSearchPreviewHits(page: Page): Promise<number> {
	const summaryText = await page
		.getByTestId('search-preview-results')
		.getByText(/\d+\s+hits\b/i)
		.textContent();
	const matchedCount = summaryText?.match(/(\d+)\s+hits\b/i);
	if (!matchedCount) {
		throw new Error(`Could not parse hit count from summary: ${summaryText ?? '<empty>'}`);
	}
	return Number.parseInt(matchedCount[1], 10);
}

export async function waitForSearchPreviewTotalHits(
	page: Page,
	expectedCount: number,
	timeoutMs = 30_000
): Promise<void> {
	await expect
		.poll(() => countSearchPreviewHits(page), {
			timeout: timeoutMs,
			message: `Waiting for Search preview to report ${expectedCount} hits`
		})
		.toBe(expectedCount);
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
		if (!/\/api\/search\/[^/]+\/events(?:\?|$)/.test(request.url())) {
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

export function startSearchPreviewSearchCapture(page: Page): SearchPreviewSearchCapture {
	const payloads: unknown[] = [];
	const onRequest = (request: {
		url: () => string;
		method: () => string;
		postDataJSON: () => unknown;
	}) => {
		if (request.method() !== 'POST') return;
		if (!/\/api\/search\/[^/]+(?:\?|$)/.test(request.url())) return;
		payloads.push(request.postDataJSON());
	};
	page.on('request', onRequest as never);
	return {
		payloads,
		stop: () => page.off('request', onRequest as never)
	};
}
