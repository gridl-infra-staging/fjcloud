import { test, expect } from '../../fixtures/fixtures';
import type { Locator, Page, Route } from '@playwright/test';
import { openIndexDetailTab } from '../../fixtures/index_detail_helpers';
import * as devalue from 'devalue';

type ActionResult =
	| {
			type: 'success';
			status: number;
			data: {
				recommendationsResponse: {
					results: Array<{ hits: Array<Record<string, unknown>>; processingTimeMS: number }>;
				};
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

async function submitRecommendations(section: Locator) {
	await section.getByRole('button', { name: 'Get Recommendations' }).click();
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

test.describe('Recommendations tab rendering', () => {
	test('happy-path submit renders recommendation hits', async ({
		page,
		seedRecommendationsConfig,
		testRegion
	}) => {
		const { section, seeded } = await openRecommendationsSection(
			page,
			seedRecommendationsConfig,
			testRegion,
			'e2e-rec-hits'
		);

		await page.route('**/console/indexes/**', async (route) => {
			const request = route.request();
			if (request.method() !== 'POST' || !request.url().includes('recommend')) {
				await route.continue();
				return;
			}

			const body: ActionResult = {
				type: 'success',
				status: 200,
				data: {
					recommendationsResponse: {
						results: [{ hits: [{ objectID: 'visible-hit-1' }, { objectID: 'visible-hit-2' }], processingTimeMS: 12 }]
					}
				}
			};
			await fulfillRecommendationsAction(route, body);
		});

		await section.getByLabel('Object ID').fill(seeded.primaryObjectID);
		await submitRecommendations(section);
		await expect(section.getByText('visible-hit-1')).toBeVisible();
		await expect(section.getByText('visible-hit-2')).toBeVisible();
	});

	test('forced failure submit renders recommendations error in alert region', async ({
		page,
		seedRecommendationsConfig,
		testRegion
	}) => {
		const { section, seeded } = await openRecommendationsSection(
			page,
			seedRecommendationsConfig,
			testRegion,
			'e2e-rec-failure'
		);

		await page.route('**/console/indexes/**', async (route) => {
			const request = route.request();
			if (request.method() !== 'POST' || !request.url().includes('recommend')) {
				await route.continue();
				return;
			}

			const body: ActionResult = {
				type: 'failure',
				status: 400,
				data: { recommendationsError: 'Forced recommendations failure' }
			};
			await fulfillRecommendationsAction(route, body);
		});

		await section.getByLabel('Object ID').fill(seeded.primaryObjectID);
		await submitRecommendations(section);
		await expect(section.getByRole('alert')).toHaveText(/Forced recommendations failure/);
	});

	test('all-empty recommendation results render one aggregate empty-state copy', async ({
		page,
		seedRecommendationsConfig,
		testRegion
	}) => {
		const { section, seeded } = await openRecommendationsSection(
			page,
			seedRecommendationsConfig,
			testRegion,
			'e2e-rec-empty'
		);

		await page.route('**/console/indexes/**', async (route) => {
			const request = route.request();
			if (request.method() !== 'POST' || !request.url().includes('recommend')) {
				await route.continue();
				return;
			}

			const body: ActionResult = {
				type: 'success',
				status: 200,
				data: {
					recommendationsResponse: {
						results: [
							{ hits: [], processingTimeMS: 2 },
							{ hits: [], processingTimeMS: 3 }
						]
					}
				}
			};
			await fulfillRecommendationsAction(route, body);
		});

		await section.getByLabel('Object ID').fill(seeded.primaryObjectID);
		await submitRecommendations(section);
		await expect(section.getByText('No recommendations found.')).toBeVisible();
		await expect(section.getByText('No hits returned.')).toHaveCount(0);
	});
});
