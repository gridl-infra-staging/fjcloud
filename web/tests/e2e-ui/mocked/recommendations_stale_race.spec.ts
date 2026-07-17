import { test, expect } from '../../fixtures/fixtures';
import {
	openIndexDetailTab,
	recommendationField,
	setRecommendationRequestPayloadForNextSubmit
} from '../../fixtures/index_detail_helpers';
import * as devalue from 'devalue';
import type { Route } from '@playwright/test';

const PRIMARY_OBJECT_ID = 'doc-1';
const SECONDARY_OBJECT_ID = 'doc-2';

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

test('recommendations drops stale first response when second submit wins', async ({
	page,
	seedIndex,
	testRegion
}) => {
	const indexName = `e2e-rec-stale-mocked-${Date.now()}`;
	await seedIndex(indexName, testRegion);
	await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
	const section = await openIndexDetailTab(page, 'Recommendations', 'recommendations-section');

	let releaseFirstResponse = () => {};
	const firstResponseGate = new Promise<void>((resolve) => {
		releaseFirstResponse = resolve;
	});
	let requestCount = 0;
	let firstRequestPayload = '';
	let secondRequestPayload = '';
	let firstCaptured = false;

	await page.route('**/console/indexes/**', async (route) => {
		const request = route.request();
		if (request.method() !== 'POST' || !request.url().includes('recommend')) {
			await route.continue();
			return;
		}

		requestCount += 1;
		const requestBody = request.postData() ?? '';

		if (requestCount === 1) {
			firstCaptured = true;
			firstRequestPayload = requestBody;
			await firstResponseGate;
			await fulfillRecommendationsAction(route, {
				type: 'failure',
				status: 400,
				data: { recommendationsError: 'stale-first-response-error' }
			});
			return;
		}

		secondRequestPayload = requestBody;
		await fulfillRecommendationsAction(route, {
			type: 'success',
			status: 200,
			data: {
				recommendationsResponse: {
					results: [{ hits: [{ objectID: 'fresh-second-hit' }], processingTimeMS: 5 }]
				},
				recommendationsError: ''
			}
		});
	});

	await recommendationField(section, 'objectId').fill(PRIMARY_OBJECT_ID);
	await setRecommendationRequestPayloadForNextSubmit(section, '{"requests":"broken"}');
	await section.getByRole('button', { name: 'Get Recommendations' }).click();

	await section.getByTestId('recommendations-model-select').selectOption('looking-similar');
	await recommendationField(section, 'objectId').fill(SECONDARY_OBJECT_ID);
	await section.getByRole('button', { name: 'Get Recommendations' }).click();

	await expect.poll(() => requestCount).toBe(2);
	await expect.poll(() => firstCaptured).toBeTruthy();
	releaseFirstResponse();
	await expect(section.getByText('fresh-second-hit')).toBeVisible();
	await expect(section.getByRole('alert')).toHaveCount(0);
	expect(firstRequestPayload).not.toEqual(secondRequestPayload);
	await expect(section.getByTestId('recommendations-model-select')).toHaveValue('looking-similar');
});
