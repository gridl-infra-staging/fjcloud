import { test, expect } from '../../fixtures/fixtures';
import type { Locator, Page, Route } from '@playwright/test';
import * as devalue from 'devalue';
import { openIndexDetailTab } from '../../fixtures/index_detail_helpers';

type ActionResult =
	| {
			type: 'success';
			status: number;
			data: {
				recommendationsResponse: {
					results: Array<{ hits: Array<Record<string, unknown>>; processingTimeMS: number }>;
				};
				recommendationsError: string;
			};
	  }
	| {
			type: 'failure';
			status: number;
			data: { recommendationsError: string };
	  };

type SeedRecommendationsConfigFn = (
	name: string,
	region?: string
) => Promise<{
	indexName: string;
	primaryObjectID: string;
	secondaryObjectID: string;
	facetName: string;
	facetValue: string;
	missingFacetValue: string;
}>;

async function openRecommendationsSection(
	page: Page,
	seedRecommendationsConfig: SeedRecommendationsConfigFn,
	testRegion: string,
	namePrefix: string
) {
	const indexName = `${namePrefix}-${Date.now()}`;
	const seeded = await seedRecommendationsConfig(indexName, testRegion);
	await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
	const section = await openIndexDetailTab(page, 'Recommendations', 'recommendations-section');
	return { section, seeded };
}

async function fulfillRecommendationsAction(route: Route, nextResult: ActionResult) {
	const response = await route.fetch();
	const payload = (await response.json()) as Record<string, unknown>;
	const nextPayload = {
		...payload,
		type: nextResult.type,
		status: nextResult.status,
		data: devalue.stringify(nextResult.data)
	};
	await route.fulfill({
		status: response.status(),
		headers: response.headers(),
		body: JSON.stringify(nextPayload)
	});
}

async function openEditDialog(section: Locator) {
	await section.getByRole('button', { name: 'Edit Configuration' }).click();
	const dialog = section.page().getByTestId('recommendations-edit-dialog');
	await expect(dialog).toBeVisible();
	return dialog;
}

async function assertModelFieldSet(
	dialog: Locator,
	model: string,
	expectObjectID: boolean,
	expectFacetFields: boolean
) {
	await dialog.getByLabel('Model').selectOption(model);
	await expect(dialog.getByLabel('Object ID')).toHaveCount(expectObjectID ? 1 : 0);
	await expect(dialog.getByLabel('Facet Name')).toHaveCount(expectFacetFields ? 1 : 0);
	await expect(dialog.getByLabel('Facet Value')).toHaveCount(expectFacetFields ? 1 : 0);
	await expect(dialog.getByLabel('Threshold')).toBeVisible();
	await expect(dialog.getByLabel('Max Recommendations')).toBeVisible();
}

test.describe('Recommendations edit configuration dialog', () => {
	test('edit configuration updates inline state and waits for explicit submit', async ({
		page,
		seedRecommendationsConfig,
		testRegion
	}) => {
		const { section, seeded } = await openRecommendationsSection(
			page,
			seedRecommendationsConfig,
			testRegion,
			'e2e-rec-edit-config'
		);

		let recommendationsSubmitCount = 0;
		await page.route('**/console/indexes/**', async (route) => {
			const request = route.request();
			if (request.method() !== 'POST' || !request.url().includes('recommend')) {
				await route.continue();
				return;
			}
			recommendationsSubmitCount += 1;
			await fulfillRecommendationsAction(route, {
				type: 'success',
				status: 200,
				data: {
					recommendationsResponse: {
						results: [{ hits: [{ facet_name: 'brand', facet_value: 'Apple' }], processingTimeMS: 7 }]
					},
					recommendationsError: ''
				}
			});
		});

		const dialog = await openEditDialog(section);
		await dialog.getByLabel('Model').selectOption('trending-facets');
		await dialog.getByLabel('Facet Name').fill(seeded.facetName);
		await dialog.getByLabel('Facet Value').fill(seeded.facetValue);
		await dialog.getByLabel('Threshold').fill('12');
		await dialog.getByLabel('Max Recommendations').fill('9');
		await dialog.getByTestId('editor-dialog-save').click();

		await expect(dialog).toHaveCount(0);
		await expect.poll(() => recommendationsSubmitCount).toBe(0);

		await expect(section.getByTestId('recommendations-model-select')).toHaveValue('trending-facets');
		await expect(section.getByLabel('Facet Name')).toHaveValue(seeded.facetName);
		await expect(section.getByLabel('Facet Value')).toHaveValue(seeded.facetValue);
		await expect(section.getByLabel('Threshold')).toHaveValue('12');
		await expect(section.getByLabel('Max Recommendations')).toHaveValue('9');
		await expect(section.getByLabel('Object ID')).toHaveCount(0);

		await section.getByRole('button', { name: 'Get Recommendations' }).click();
		await expect.poll(() => recommendationsSubmitCount).toBe(1);
		await expect(section.getByText('brand: Apple')).toBeVisible();
	});

	test('related-products shows objectID and keeps thresholds visible', async ({
		page,
		seedRecommendationsConfig,
		testRegion
	}) => {
		const { section } = await openRecommendationsSection(
			page,
			seedRecommendationsConfig,
			testRegion,
			'e2e-rec-model-related-products'
		);
		const dialog = await openEditDialog(section);
		await assertModelFieldSet(dialog, 'related-products', true, false);
	});

	test('bought-together shows objectID and keeps thresholds visible', async ({
		page,
		seedRecommendationsConfig,
		testRegion
	}) => {
		const { section } = await openRecommendationsSection(
			page,
			seedRecommendationsConfig,
			testRegion,
			'e2e-rec-model-bought-together'
		);
		const dialog = await openEditDialog(section);
		await assertModelFieldSet(dialog, 'bought-together', true, false);
	});

	test('looking-similar shows objectID and keeps thresholds visible', async ({
		page,
		seedRecommendationsConfig,
		testRegion
	}) => {
		const { section } = await openRecommendationsSection(
			page,
			seedRecommendationsConfig,
			testRegion,
			'e2e-rec-model-looking-similar'
		);
		const dialog = await openEditDialog(section);
		await assertModelFieldSet(dialog, 'looking-similar', true, false);
	});

	test('trending-items hides objectID and facet fields while keeping thresholds visible', async ({
		page,
		seedRecommendationsConfig,
		testRegion
	}) => {
		const { section } = await openRecommendationsSection(
			page,
			seedRecommendationsConfig,
			testRegion,
			'e2e-rec-model-trending-items'
		);
		const dialog = await openEditDialog(section);
		await assertModelFieldSet(dialog, 'trending-items', false, false);
	});

	test('trending-facets shows facet fields and hides objectID while keeping thresholds visible', async ({
		page,
		seedRecommendationsConfig,
		testRegion
	}) => {
		const { section } = await openRecommendationsSection(
			page,
			seedRecommendationsConfig,
			testRegion,
			'e2e-rec-model-trending-facets'
		);
		const dialog = await openEditDialog(section);
		await assertModelFieldSet(dialog, 'trending-facets', false, true);
	});
});
