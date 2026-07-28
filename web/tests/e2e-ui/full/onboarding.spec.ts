/**
 * Full — Onboarding (fresh user)
 *
 * Verifies the fresh-user onboarding path: dashboard banner entry,
 * onboarding wizard step 1 (region + index name form), inline validation,
 * and successful index creation advancing to step 3 (credentials).
 *
 * Uses the chromium:onboarding project with a freshly signed-up account
 * that has never completed onboarding.
 */

import type { Page, Response } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';
import { verifyFreshSignupEmail } from '../../fixtures/onboarding-auth-shared';

type OnboardingActionPost = {
	action: string;
	status: number;
};

type OnboardingActionFailureScenario = {
	actionPosts: OnboardingActionPost[];
	dispose: () => Promise<void>;
};

type FreshSignupIdentityLike = {
	name: string;
	email: string;
	password: string;
};

type ArrangeFreshSignupToDashboardFn = (
	page: Page,
	signup: FreshSignupIdentityLike
) => Promise<{ prerequisiteFailureMessage: string | null }>;

async function openOnboardingStepOne(page: Page): Promise<void> {
	await page.goto('/console');
	await page.getByTestId('onboarding-banner').getByRole('link', { name: 'Continue setup' }).click();
	await expect(page).toHaveURL(/\/console\/onboarding/);
	await expect(page.getByTestId('onboarding-step-1')).toBeVisible();
}

function isOnboardingCreateOrRetryAction(url: URL): boolean {
	return (
		url.pathname === '/console/onboarding' &&
		(url.search === '?/createIndex' || url.search === '?/retryIndex')
	);
}

function buildMissingNamePostData(postData: string | null): string {
	const form = new URLSearchParams(postData ?? '');
	form.set('name', '');
	return form.toString();
}

async function setupOnboardingActionFailureScenario(
	page: Page
): Promise<OnboardingActionFailureScenario> {
	let failFirstCreatePost = true;
	const actionPosts: OnboardingActionPost[] = [];
	const actionRoute = (url: URL) => isOnboardingCreateOrRetryAction(url);
	const handleResponse = (response: Response) => {
		const request = response.request();
		const url = new URL(response.url());
		if (request.method() === 'POST' && isOnboardingCreateOrRetryAction(url)) {
			actionPosts.push({ action: url.search, status: response.status() });
		}
	};

	page.on('response', handleResponse);
	await page.route(actionRoute, async (route) => {
		const request = route.request();
		const url = new URL(request.url());
		if (failFirstCreatePost && request.method() === 'POST' && url.search === '?/createIndex') {
			failFirstCreatePost = false;
			await route.continue({
				headers: {
					...request.headers(),
					'content-type': 'application/x-www-form-urlencoded'
				},
				postData: buildMissingNamePostData(request.postData())
			});
			return;
		}
		await route.continue();
	});

	return {
		actionPosts,
		dispose: async () => {
			page.off('response', handleResponse);
			await page.unroute(actionRoute);
		}
	};
}

async function arrangeIsolatedFreshVerifiedOnboardingAccount(
	page: Page,
	createFreshSignupIdentity: () => FreshSignupIdentityLike,
	arrangeFreshSignupToDashboard: ArrangeFreshSignupToDashboardFn
): Promise<void> {
	const signup = createFreshSignupIdentity();
	const arrangeResult = await arrangeFreshSignupToDashboard(page, signup);
	if (arrangeResult.prerequisiteFailureMessage) {
		throw new Error(
			`Onboarding create-flow prerequisite unavailable: ${arrangeResult.prerequisiteFailureMessage}`
		);
	}

	await verifyFreshSignupEmail(signup.email);
	await page.goto('/console');
	await expect(page.getByTestId('onboarding-banner')).toBeVisible({ timeout: 30_000 });
}

async function restoreFreshOnboardingBanner(page: Page, indexName: string): Promise<void> {
	// The attempted action may have created the index even when a later
	// assertion fails. Check for it unconditionally so cleanup remains
	// idempotent before and after a successful mutation.
	await page.goto('/console/indexes');

	const createdRow = page.getByRole('row').filter({
		has: page.getByRole('link', { name: indexName })
	});
	const deleteButton = createdRow.getByRole('button', { name: 'Delete' });

	const createdRowCount = await createdRow.count();
	expect(createdRowCount, `cleanup found duplicate rows for ${indexName}`).toBeLessThanOrEqual(1);

	if (createdRowCount === 1) {
		await expect(deleteButton).toBeVisible({ timeout: 30_000 });
		await deleteButton.click();
		await expect(page.getByRole('cell', { name: indexName })).toHaveCount(0, {
			timeout: 30_000
		});
	}

	await page.goto('/console');
	await expect(page.getByTestId('onboarding-banner')).toBeVisible({ timeout: 30_000 });
}

async function runWithOnboardingCleanup(
	exercise: () => Promise<void>,
	cleanup: () => Promise<void>
): Promise<void> {
	try {
		await exercise();
	} finally {
		await cleanup();
	}
}

async function recoverFromOnboardingCreateFailure(
	page: Page,
	scenario: OnboardingActionFailureScenario,
	indexName: string
): Promise<void> {
	await openOnboardingStepOne(page);

	const nameInput = page.getByLabel('Index name');
	await nameInput.clear();
	await nameInput.fill(indexName);

	await page.getByRole('button', { name: 'Continue' }).click();
	await expect.poll(() => scenario.actionPosts.length, { timeout: 90_000 }).toBe(1);
	expect(scenario.actionPosts[0]).toEqual({ action: '?/createIndex', status: 200 });
	await expect(page.getByTestId('onboarding-step-1')).toBeVisible();
	await expect(page.getByText('Index name and region are required')).toBeVisible();
	await expect(page.getByRole('button', { name: 'Continue' })).toBeEnabled();

	await page.getByRole('button', { name: 'Continue' }).click();
	await expect.poll(() => scenario.actionPosts.length, { timeout: 90_000 }).toBe(2);
	expect(scenario.actionPosts[1].action).toBe('?/retryIndex');
	expect(scenario.actionPosts[1].status).toBeLessThan(400);
	await expect(page.getByTestId('onboarding-step-3')).toBeVisible({ timeout: 90_000 });
	await expect(
		page.getByTestId('onboarding-step-3').getByRole('button', { name: 'Get Credentials' })
	).toBeVisible({ timeout: 90_000 });
}

test.describe('Fresh-user onboarding flow', () => {
	// Read-only cases share the setup account; create flows below use disposable
	// accounts. Keep retries disabled because each create flow owns explicit index
	// cleanup and verifies that its onboarding banner is restored.
	test.describe.configure({ retries: 0 });

	test('load-and-verify: dashboard shows onboarding banner for fresh user', async ({ page }) => {
		await page.goto('/console');

		await expect(page.getByRole('heading', { name: 'Console' })).toBeVisible();
		await expect(page.getByTestId('onboarding-banner')).toBeVisible();
		await expect(
			page.getByTestId('onboarding-banner').getByText('Complete your setup')
		).toBeVisible();
		await expect(
			page.getByTestId('onboarding-banner').getByRole('link', { name: 'Continue setup' })
		).toBeVisible();
	});

	test('dashboard banner navigates to onboarding wizard step 1', async ({ page }) => {
		await openOnboardingStepOne(page);
		await expect(page.getByRole('heading', { name: 'Get Started' })).toBeVisible();
	});

	test('onboarding step 1 renders region picker and index name form', async ({ page }) => {
		await openOnboardingStepOne(page);

		// Region picker shows available regions
		await expect(page.getByText('US East (Virginia)')).toBeVisible();
		await expect(page.getByText('EU West (Ireland)')).toBeVisible();

		// Index name input with default value
		const nameInput = page.getByLabel('Index name');
		await expect(nameInput).toBeVisible();
		await expect(nameInput).toHaveValue('my-first-index');

		// Continue button
		await expect(page.getByRole('button', { name: 'Continue' })).toBeVisible();
	});

	test('invalid index name shows inline validation error', async ({ page }) => {
		await openOnboardingStepOne(page);

		const nameInput = page.getByLabel('Index name');

		// Clear default and type an invalid name starting with a hyphen
		await nameInput.clear();
		await nameInput.fill('-invalid-name');
		await expect(page.getByTestId('index-name-error')).toBeVisible();
		await expect(page.getByTestId('index-name-error')).toContainText(
			'must start and end with a letter or number'
		);

		// Continue button should be disabled with invalid name
		await expect(page.getByRole('button', { name: 'Continue' })).toBeDisabled();

		// Fix the name — error should disappear
		await nameInput.clear();
		await nameInput.fill('valid-test-index');
		await expect(page.getByTestId('index-name-error')).toBeHidden();
		await expect(page.getByRole('button', { name: 'Continue' })).toBeEnabled();
	});

	test('empty index name shows required error and keeps Continue disabled', async ({ page }) => {
		await openOnboardingStepOne(page);

		const nameInput = page.getByLabel('Index name');
		await nameInput.clear();

		await expect(page.getByTestId('index-name-error')).toBeVisible();
		await expect(page.getByTestId('index-name-error')).toContainText('Index name is required');
		await expect(page.getByRole('button', { name: 'Continue' })).toBeDisabled();
	});

	test.describe('isolated onboarding create flows', () => {
		test.use({ storageState: { cookies: [], origins: [] } });

		test('cleanup guard restores the onboarding banner after a successful second POST followed by an assertion failure', async ({
			page,
			createFreshSignupIdentity,
			arrangeFreshSignupToDashboard
		}) => {
			test.setTimeout(150_000);

			await arrangeIsolatedFreshVerifiedOnboardingAccount(
				page,
				createFreshSignupIdentity,
				arrangeFreshSignupToDashboard
			);

			const indexName = `onboard-cleanup-${Date.now()}`;
			const expectedAssertionMessage = 'post-submit cleanup regression sentinel';
			const scenario = await setupOnboardingActionFailureScenario(page);

			try {
				await expect(
					runWithOnboardingCleanup(
						async () => {
							await recoverFromOnboardingCreateFailure(page, scenario, indexName);
							throw new Error(expectedAssertionMessage);
						},
						() => restoreFreshOnboardingBanner(page, indexName)
					)
				).rejects.toThrow(expectedAssertionMessage);

				await expect(page.getByTestId('onboarding-banner')).toBeVisible({ timeout: 30_000 });
			} finally {
				await scenario.dispose();
			}
		});

		test('valid index creation advances to step 3 credentials UI', async ({
			page,
			createFreshSignupIdentity,
			arrangeFreshSignupToDashboard
		}) => {
			test.setTimeout(120_000);

			await arrangeIsolatedFreshVerifiedOnboardingAccount(
				page,
				createFreshSignupIdentity,
				arrangeFreshSignupToDashboard
			);

			const indexName = `onboard-${Date.now()}`;

			await runWithOnboardingCleanup(
				async () => {
					await openOnboardingStepOne(page);

					// Fill the index name
					const nameInput = page.getByLabel('Index name');
					await nameInput.clear();
					await nameInput.fill(indexName);

					// Submit the form
					await page.getByRole('button', { name: 'Continue' }).click();

					// Shared-VM placement can auto-provision capacity on live stacks, so the
					// createIndex action can exceed Playwright's default 30s budget.
					await expect(page.getByTestId('onboarding-step-3')).toBeVisible({ timeout: 90_000 });
					await expect(
						page.getByTestId('onboarding-step-3').getByRole('button', { name: 'Get Credentials' })
					).toBeVisible({ timeout: 90_000 });
				},
				() => restoreFreshOnboardingBanner(page, indexName)
			);
		});

		test('row 11 @p0_coverage onboarding create failure retries through existing action path and recovers credentials state', async ({
			page,
			createFreshSignupIdentity,
			arrangeFreshSignupToDashboard
		}) => {
			test.setTimeout(150_000);

			await arrangeIsolatedFreshVerifiedOnboardingAccount(
				page,
				createFreshSignupIdentity,
				arrangeFreshSignupToDashboard
			);

			const indexName = `onboard-retry-${Date.now()}`;
			const scenario = await setupOnboardingActionFailureScenario(page);

			try {
				await runWithOnboardingCleanup(
					() => recoverFromOnboardingCreateFailure(page, scenario, indexName),
					() => restoreFreshOnboardingBanner(page, indexName)
				);
				expect(scenario.actionPosts).toHaveLength(2);
			} finally {
				await scenario.dispose();
			}
		});
	});
});
