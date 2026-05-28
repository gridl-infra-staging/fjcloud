import { test, expect } from '../../fixtures/fixtures';
import { openIndexDetailTab } from '../../fixtures/index_detail_helpers';
import type { RecommendationsBatchRequest } from '$lib/api/types';
import type { Page, Route } from '@playwright/test';

const PRIMARY_OBJECT_ID = 'doc-1';
const SECONDARY_OBJECT_ID = 'doc-2';
const FACET_NAME = 'category';
const FACET_VALUE = 'language';

function decodeRequestBody(postData: string): RecommendationsBatchRequest {
	const params = new URLSearchParams(postData);
	const encodedRequest = params.get('request');
	if (!encodedRequest) {
		throw new Error('Missing request field in recommendations form payload');
	}
	return JSON.parse(encodedRequest) as RecommendationsBatchRequest;
}

async function captureRecommendationRequest(
	page: Page,
	capturedRequests: RecommendationsBatchRequest[]
): Promise<void> {
	await page.route('**/console/indexes/**', async (route: Route) => {
		const request = route.request();
		if (request.method() !== 'POST' || !request.url().includes('recommend')) {
			await route.continue();
			return;
		}
		capturedRequests.push(decodeRequestBody(request.postData() ?? ''));
		await route.fulfill({
			status: 200,
			contentType: 'application/json',
			body: JSON.stringify({
				type: 'success',
				status: 200,
				data: {
					recommendationsResponse: {
						results: []
					}
				}
			})
		});
	});
}

test.describe('Recommendations request wire contract', () => {
	test('related-products request body is exact', async ({ page, seedIndex, testRegion }) => {
		const indexName = `e2e-rec-wire-related-products-${Date.now()}`;
		await seedIndex(indexName, testRegion);
		await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
		const section = await openIndexDetailTab(page, 'Recommendations', 'recommendations-section');

		const captured: RecommendationsBatchRequest[] = [];
		await captureRecommendationRequest(page, captured);

		await section.getByLabel('Object ID').fill(PRIMARY_OBJECT_ID);
		await section.getByLabel('Threshold').fill('4');
		await section.getByLabel('Max Recommendations').fill('6');
		await section.getByRole('button', { name: 'Get Recommendations' }).click();
		await expect.poll(() => captured.length).toBe(1);
		expect(captured[0]).toEqual({
			requests: [
				{
					indexName,
					model: 'related-products',
					objectID: PRIMARY_OBJECT_ID,
					threshold: 4,
					maxRecommendations: 6
				}
			]
		});
	});

	test('bought-together request body is exact', async ({ page, seedIndex, testRegion }) => {
		const indexName = `e2e-rec-wire-bought-together-${Date.now()}`;
		await seedIndex(indexName, testRegion);
		await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
		const section = await openIndexDetailTab(page, 'Recommendations', 'recommendations-section');

		const captured: RecommendationsBatchRequest[] = [];
		await captureRecommendationRequest(page, captured);

		await section.getByTestId('recommendations-model-select').selectOption('bought-together');
		await section.getByLabel('Object ID').fill(SECONDARY_OBJECT_ID);
		await section.getByLabel('Threshold').fill('5');
		await section.getByLabel('Max Recommendations').fill('10');
		await section.getByRole('button', { name: 'Get Recommendations' }).click();
		await expect.poll(() => captured.length).toBe(1);
		expect(captured[0]).toEqual({
			requests: [
				{
					indexName,
					model: 'bought-together',
					objectID: SECONDARY_OBJECT_ID,
					threshold: 5,
					maxRecommendations: 10
				}
			]
		});
	});

	test('looking-similar request body is exact', async ({ page, seedIndex, testRegion }) => {
		const indexName = `e2e-rec-wire-looking-similar-${Date.now()}`;
		await seedIndex(indexName, testRegion);
		await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
		const section = await openIndexDetailTab(page, 'Recommendations', 'recommendations-section');

		const captured: RecommendationsBatchRequest[] = [];
		await captureRecommendationRequest(page, captured);

		await section.getByTestId('recommendations-model-select').selectOption('looking-similar');
		await section.getByLabel('Object ID').fill(PRIMARY_OBJECT_ID);
		await section.getByLabel('Threshold').fill('7');
		await section.getByLabel('Max Recommendations').fill('11');
		await section.getByRole('button', { name: 'Get Recommendations' }).click();
		await expect.poll(() => captured.length).toBe(1);
		expect(captured[0]).toEqual({
			requests: [
				{
					indexName,
					model: 'looking-similar',
					objectID: PRIMARY_OBJECT_ID,
					threshold: 7,
					maxRecommendations: 11
				}
			]
		});
	});

	test('trending-items request body is exact', async ({ page, seedIndex, testRegion }) => {
		const indexName = `e2e-rec-wire-trending-items-${Date.now()}`;
		await seedIndex(indexName, testRegion);
		await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
		const section = await openIndexDetailTab(page, 'Recommendations', 'recommendations-section');

		const captured: RecommendationsBatchRequest[] = [];
		await captureRecommendationRequest(page, captured);

		await section.getByTestId('recommendations-model-select').selectOption('trending-items');
		await section.getByLabel('Threshold').fill('2');
		await section.getByLabel('Max Recommendations').fill('4');
		await section.getByRole('button', { name: 'Get Recommendations' }).click();
		await expect.poll(() => captured.length).toBe(1);
		expect(captured[0]).toEqual({
			requests: [
				{
					indexName,
					model: 'trending-items',
					threshold: 2,
					maxRecommendations: 4
				}
			]
		});
	});

	test('trending-facets request body is exact', async ({ page, seedIndex, testRegion }) => {
		const indexName = `e2e-rec-wire-trending-facets-${Date.now()}`;
		await seedIndex(indexName, testRegion);
		await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
		const section = await openIndexDetailTab(page, 'Recommendations', 'recommendations-section');

		const captured: RecommendationsBatchRequest[] = [];
		await captureRecommendationRequest(page, captured);

		await section.getByTestId('recommendations-model-select').selectOption('trending-facets');
		await section.getByLabel('Facet Name').fill(FACET_NAME);
		await section.getByLabel('Facet Value').fill(FACET_VALUE);
		await section.getByLabel('Threshold').fill('3');
		await section.getByLabel('Max Recommendations').fill('5');
		await section.getByRole('button', { name: 'Get Recommendations' }).click();
		await expect.poll(() => captured.length).toBe(1);
		expect(captured[0]).toEqual({
			requests: [
				{
					indexName,
					model: 'trending-facets',
					facetName: FACET_NAME,
					facetValue: FACET_VALUE,
					threshold: 3,
					maxRecommendations: 5
				}
			]
		});
	});
});
