import { test, expect } from '../../fixtures/fixtures';
import type { Locator, Page, Route } from '@playwright/test';
import { openIndexDetailTab } from '../../fixtures/index_detail_helpers';
import * as devalue from 'devalue';
import { seedSearchableIndexForCustomer } from '../../fixtures/searchable-index';
import { AUTH_COOKIE } from '../../../src/lib/server/auth-session-contracts';

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

type SeededRecommendationsConfig = {
	indexName: string;
	primaryObjectID: string;
	secondaryObjectID: string;
	facetName: string;
	facetValue: string;
	missingFacetValue: string;
};

type CreatedFixtureUser = {
	customerId: string;
	email: string;
	token: string;
};

type CreateUserFn = (email: string, password: string, name?: string) => Promise<CreatedFixtureUser>;
type LoginAsFn = (email: string, password: string) => Promise<string>;

const BASE_URL = process.env.BASE_URL ?? 'http://localhost:5173';
const API_URL = process.env.API_URL ?? 'http://localhost:3001';
const RECOMMENDATION_FIXTURE_FACET_NAME = 'category';
const RECOMMENDATION_FIXTURE_FACET_VALUE = 'language';
const RECOMMENDATION_FIXTURE_MISSING_FACET_VALUE = 'no-matches-category';
const FIXTURE_PASSWORD = 'TestPassword123!';

async function openRecommendationsSection(
	page: Page,
	createUser: CreateUserFn,
	loginAs: LoginAsFn,
	testRegion: string,
	namePrefix: string
) {
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
				[RECOMMENDATION_FIXTURE_FACET_NAME]: RECOMMENDATION_FIXTURE_FACET_VALUE
			},
			{
				objectID: 'doc-2',
				title: 'TypeScript Handbook',
				body: 'JavaScript with types',
				[RECOMMENDATION_FIXTURE_FACET_NAME]: RECOMMENDATION_FIXTURE_FACET_VALUE
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
	return {
		section,
		seeded: {
			indexName,
			primaryObjectID: 'doc-1',
			secondaryObjectID: 'doc-2',
			facetName: RECOMMENDATION_FIXTURE_FACET_NAME,
			facetValue: RECOMMENDATION_FIXTURE_FACET_VALUE,
			missingFacetValue: RECOMMENDATION_FIXTURE_MISSING_FACET_VALUE
		} satisfies SeededRecommendationsConfig
	};
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
	test.describe.configure({ timeout: 120_000 });

	test('happy-path submit renders recommendation hits', async ({
		page,
		createUser,
		loginAs,
		testRegion
	}) => {
		const { section, seeded } = await openRecommendationsSection(
			page,
			createUser,
			loginAs,
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
						results: [
							{
								hits: [{ objectID: 'visible-hit-1' }, { objectID: 'visible-hit-2' }],
								processingTimeMS: 12
							}
						]
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
		createUser,
		loginAs,
		testRegion
	}) => {
		const { section, seeded } = await openRecommendationsSection(
			page,
			createUser,
			loginAs,
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
		createUser,
		loginAs,
		testRegion
	}) => {
		const { section, seeded } = await openRecommendationsSection(
			page,
			createUser,
			loginAs,
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
