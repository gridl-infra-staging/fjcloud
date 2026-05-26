import { test, expect } from '../../fixtures/fixtures';
import { openIndexDetailTab } from '../../fixtures/index_detail_helpers';

test('real-stack stale race keeps second submission visible after late first completion', async ({
	page,
	seedRecommendationsConfig,
	testRegion
}) => {
	const indexName = `e2e-rec-stale-real-${Date.now()}`;
	const seeded = await seedRecommendationsConfig(indexName, testRegion);
	await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
	const section = await openIndexDetailTab(page, 'Recommendations', 'recommendations-section');

	let releaseFirstResponse = () => {};
	const firstResponseGate = new Promise<void>((resolve) => {
		releaseFirstResponse = resolve;
	});
	let requestCount = 0;

	await page.route('**/console/indexes/**', async (route) => {
		const request = route.request();
		if (request.method() !== 'POST' || !request.url().includes('recommend')) {
			await route.continue();
			return;
		}

		requestCount += 1;
		if (requestCount === 1) {
			await firstResponseGate;
		}
		await route.continue();
	});

	await section.getByLabel('Object ID').fill(seeded.primaryObjectID);
	await page.evaluate(() => {
		const requestInput = document.querySelector('input[name="request"]') as HTMLInputElement | null;
		if (requestInput) {
			requestInput.value = '{"requests":"broken"}';
		}
	});
	await section.getByRole('button', { name: 'Get Recommendations' }).click();

	await section.getByTestId('recommendations-model-select').selectOption('looking-similar');
	await section.getByLabel('Object ID').fill(seeded.secondaryObjectID);
	await section.getByRole('button', { name: 'Get Recommendations' }).click();

	await expect.poll(() => requestCount).toBe(2);
	releaseFirstResponse();
	await expect(section.getByText('request.requests must be an array')).toHaveCount(0);
	await expect(
		section.getByText(/Request #1\s+·\s+\d+ ms|No recommendations found\./).first()
	).toBeVisible();
	await expect(section.getByTestId('recommendations-model-select')).toHaveValue('looking-similar');
});
