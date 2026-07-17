import type { Locator, Page } from '@playwright/test';
import { expect } from '@playwright/test';

export type SeedIndexFn = (name: string, region?: string) => Promise<void>;
export type RecommendationFieldId =
	| 'objectId'
	| 'facetName'
	| 'facetValue'
	| 'threshold'
	| 'maxRecommendations';

const RECOMMENDATION_FIELD_LABELS: Record<RecommendationFieldId, string> = {
	objectId: 'Object ID',
	facetName: 'Facet Name',
	facetValue: 'Facet Value',
	threshold: 'Threshold',
	maxRecommendations: 'Max Recommendations'
};

function tabTestIdForLabel(tabName: string): string {
	return `tab-${tabName.trim().toLowerCase().replaceAll(' ', '-')}`;
}

/**
 * Opens an index detail tab and waits for its section to become visible.
 * When expectNotMountedBeforeOpen is true, asserts lazy-mount behavior first.
 */
export async function openIndexDetailTab(
	page: Page,
	tabName: string,
	sectionTestId: string,
	expectNotMountedBeforeOpen = true
): Promise<Locator> {
	const section = page.getByTestId(sectionTestId);
	if ((await section.count()) > 0 && (await section.first().isVisible())) {
		return section;
	}
	if (expectNotMountedBeforeOpen) {
		await expect(section).toHaveCount(0);
	}
	await expect(page.getByTestId('index-tabs-strip')).toBeVisible();
	await expect(async () => {
		const tab = page.getByTestId(tabTestIdForLabel(tabName));
		await tab.evaluate((element) => {
			element.scrollIntoView({ block: 'nearest', inline: 'center' });
		});
		await tab.click();
		await expect(tab).toHaveAttribute('aria-selected', 'true');
	}).toPass({ timeout: 10_000 });
	await expect(section).toBeVisible({ timeout: 10_000 });
	return section;
}

export async function openSeededIndexDetailPage(
	page: Page,
	seedIndex: SeedIndexFn,
	testRegion: string,
	namePrefix: string
): Promise<string> {
	const indexName = `${namePrefix}-${Date.now()}`;
	await seedIndex(indexName, testRegion);
	await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
	await expect(page.getByRole('heading', { name: indexName })).toBeVisible({ timeout: 10_000 });
	return indexName;
}

export function recommendationField(section: Locator, fieldId: RecommendationFieldId): Locator {
	return section.getByLabel(RECOMMENDATION_FIELD_LABELS[fieldId], { exact: true });
}

export async function setRecommendationRequestPayloadForNextSubmit(
	section: Locator,
	requestPayload: string
): Promise<void> {
	await section.locator('input[name="request"]').evaluate((element, value) => {
		if (element instanceof HTMLInputElement) {
			element.value = value;
		}
	}, requestPayload);
}
