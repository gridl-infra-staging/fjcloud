import { test, expect } from '../../fixtures/fixtures';
import { openIndexDetailTab } from '../../fixtures/index_detail_helpers';
import type { Locator, Page } from '@playwright/test';
import { seedSearchableIndexForCustomer } from '../../fixtures/searchable-index';
import { AUTH_COOKIE } from '../../../src/lib/server/auth-session-contracts';

const BASE_URL = process.env.BASE_URL ?? 'http://localhost:5173';
const API_URL = process.env.API_URL ?? 'http://localhost:3001';
const FIXTURE_PASSWORD = 'TestPassword123!';

type CreatedFixtureUser = {
	customerId: string;
	email: string;
	token: string;
};

type CreateUserFn = (email: string, password: string, name?: string) => Promise<CreatedFixtureUser>;
type LoginAsFn = (email: string, password: string) => Promise<string>;

async function openRecommendationsSectionForFreshCustomer(params: {
	page: Page;
	createUser: CreateUserFn;
	loginAs: LoginAsFn;
	testRegion: string;
	namePrefix: string;
}): Promise<{ section: Locator; primaryObjectID: string; secondaryObjectID: string }> {
	const { page, createUser, loginAs, testRegion, namePrefix } = params;
	const seed = Date.now();
	const indexName = `${namePrefix}-${seed}`;
	const email = `${namePrefix}-${seed}@e2e.griddle.test`;
	const createdUser = await createUser(email, FIXTURE_PASSWORD, `Recommendations ${seed}`);
	await seedSearchableIndexForCustomer({
		apiUrl: API_URL,
		adminKey: process.env.E2E_ADMIN_KEY,
		customerId: createdUser.customerId,
		token: createdUser.token,
		name: indexName,
		region: testRegion,
		query: 'Rust',
		expectedHitText: 'Rust Programming Language',
		documents: [
			{
				objectID: 'doc-1',
				title: 'Rust Programming Language',
				body: 'Systems programming',
				category: 'language'
			},
			{
				objectID: 'doc-2',
				title: 'TypeScript Handbook',
				body: 'JavaScript with types',
				category: 'language'
			}
		]
	});

	const authToken = await loginAs(email, FIXTURE_PASSWORD);
	await page.context().clearCookies();
	await page.context().addCookies([
		{
			name: AUTH_COOKIE,
			value: authToken,
			url: BASE_URL,
			httpOnly: true,
			sameSite: 'Lax'
		}
	]);
	await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
	const section = await openIndexDetailTab(page, 'Recommendations', 'recommendations-section');
	return { section, primaryObjectID: 'doc-1', secondaryObjectID: 'doc-2' };
}

test('real-stack stale race keeps second submission visible after late first completion', async ({
	page,
	createUser,
	loginAs,
	testRegion
}) => {
	test.setTimeout(120_000);

	const { section, primaryObjectID, secondaryObjectID } =
		await openRecommendationsSectionForFreshCustomer({
			page,
			createUser,
			loginAs,
			testRegion,
			namePrefix: 'e2e-rec-stale-real'
		});

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

	await section.getByLabel('Object ID').fill(primaryObjectID);
	await page.evaluate(() => {
		const requestInput = document.querySelector('input[name="request"]') as HTMLInputElement | null;
		if (requestInput) {
			requestInput.value = '{"requests":"broken"}';
		}
	});
	await section.getByRole('button', { name: 'Get Recommendations' }).click();

	await section.getByTestId('recommendations-model-select').selectOption('looking-similar');
	await section.getByLabel('Object ID').fill(secondaryObjectID);
	await section.getByRole('button', { name: 'Get Recommendations' }).click();

	await expect.poll(() => requestCount).toBe(2);
	releaseFirstResponse();
	await expect(section.getByText('request.requests must be an array')).toHaveCount(0);
	await expect(
		section.getByText(/Request #1\s+·\s+\d+ ms|No recommendations found\./).first()
	).toBeVisible();
	await expect(section.getByTestId('recommendations-model-select')).toHaveValue('looking-similar');
});
