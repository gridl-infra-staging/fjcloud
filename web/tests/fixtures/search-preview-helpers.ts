import type { Locator, Page } from '@playwright/test';
import { expect } from '@playwright/test';

type SearchPreviewState = 'generate' | 'unavailable' | 'pending';

export const SEARCH_PREVIEW_STATE_TIMEOUT_MS = 10_000;
export const SEARCH_PREVIEW_READY_TIMEOUT_MS = 90_000;
export const SEARCH_PREVIEW_READY_MESSAGE =
	'Waiting for Search Preview to become ready for preview-key generation';
export const INDEX_DETAIL_READY_TIMEOUT_MS = 30_000;
export const PREVIEW_SUBMIT_OUTCOME_TIMEOUT_MS = 5_000;

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
	const path = `/dashboard/indexes/${encodeURIComponent(indexName)}`;

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

function getIndexNameFromDetailPath(detailPath: string): string {
	return decodeURIComponent(
		new URL(detailPath, 'http://localhost').pathname.split('/').pop() ?? ''
	);
}

export async function waitForPreviewSubmitOutcome(
	page: Page,
	transientError: Locator,
	genericErrorPage: Locator
): Promise<PreviewSubmitOutcome> {
	const startedAt = Date.now();
	while (Date.now() - startedAt < PREVIEW_SUBMIT_OUTCOME_TIMEOUT_MS) {
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
		const outcome = await waitForPreviewSubmitOutcome(page, transientError, genericErrorPage);

		if (outcome === 'widget') {
			return;
		}

		if (outcome === 'generic') {
			await gotoIndexDetailWithRetry(page, indexName);
			await page.getByRole('tab', { name: 'Search Preview' }).click();
			await waitForSearchPreviewReady(page);
			await page.waitForTimeout(1000 * (attempt + 1));
			continue;
		}

		if (outcome === 'transient') {
			await page.waitForTimeout(1000 * (attempt + 1));
			continue;
		}

		break;
	}

	await waitForInstantSearchWidget(page);
}

export async function submitSearchPreviewQuery(page: Page, query: string): Promise<void> {
	const section = page.getByTestId('search-preview-section');
	const searchInput = section.getByPlaceholder('Search your index...');
	await expect(searchInput).toBeVisible({ timeout: 10_000 });
	await searchInput.click();
	await searchInput.evaluate((element, nextQuery) => {
		const input = element as HTMLInputElement;
		input.focus();
		input.value = '';
		input.dispatchEvent(new Event('input', { bubbles: true }));
		input.value = nextQuery;
		input.dispatchEvent(
			new InputEvent('input', {
				bubbles: true,
				data: nextQuery,
				inputType: 'insertText'
			})
		);
		input.dispatchEvent(new Event('change', { bubbles: true }));
	}, query);

	const submitButton = section.locator('.ais-SearchBox-submit');
	if (await submitButton.isVisible().catch(() => false)) {
		await submitButton.click();
		return;
	}

	await searchInput.press('Enter');
}
