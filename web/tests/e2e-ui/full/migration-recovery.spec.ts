/**
 * Full - Migration Recovery
 *
 * Coverage:
 *   - Bad Algolia credentials surface a visible error state that remains recoverable.
 *   - Repeated bad-credential retries keep one stable alert while the credentials form stays reusable.
 *   - Env-gated real credentials can list indexes and start migration through existing form actions.
 *
 * Boundary:
 *   - Uses only the /dashboard/migrate UI and existing ?/listIndexes + ?/migrate actions.
 *   - Does not add a second auth path, new seeding helpers, or alternate migration API routes.
 *
 * Prerequisites:
 *   - Success-path tests require E2E_ALGOLIA_APP_ID and E2E_ALGOLIA_API_KEY.
 *   - Those credentials must target a test Algolia application that already has at least one
 *     migratable source index.
 */

import type { Page } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';

const NO_ACTIVE_DEPLOYMENT_MESSAGE = 'No active deployment available';
const REAL_ALGOLIA_APP_ID = process.env.E2E_ALGOLIA_APP_ID ?? '';
const REAL_ALGOLIA_API_KEY = process.env.E2E_ALGOLIA_API_KEY ?? '';

async function openMigrationPage(page: Page): Promise<void> {
	await page.goto('/dashboard/migrate');
	await expect(page.getByRole('heading', { name: 'Migrate from Algolia' })).toBeVisible();
	await expect(page.getByTestId('credentials-form')).toBeVisible();
}

async function submitCredentialsAndListIndexes(
	page: Page,
	appId: string,
	apiKey: string
): Promise<void> {
	await page.getByLabel('App ID').fill(appId);
	await page.getByLabel('API Key').fill(apiKey);

	const listIndexesRequest = page.waitForResponse(
		(response) => response.request().method() === 'POST' && response.url().includes('?/listIndexes')
	);
	await page.getByTestId('list-indexes-button').click();
	await listIndexesRequest;
}

function skipWhenNoActiveDeployment(errorText: string, scenario: string): void {
	// eslint-disable-next-line playwright/no-skipped-test -- deployment availability is an environment precondition
	test.skip(
		errorText.includes(NO_ACTIVE_DEPLOYMENT_MESSAGE),
		`No active deployment available; ${scenario} precondition not met in this environment`
	);
}

function requireRealAlgoliaCredentials(): void {
	// eslint-disable-next-line playwright/no-skipped-test -- success-path coverage is explicitly env-gated
	test.skip(
		!REAL_ALGOLIA_APP_ID || !REAL_ALGOLIA_API_KEY,
		'E2E_ALGOLIA_APP_ID and E2E_ALGOLIA_API_KEY are required for the success path'
	);
}

async function openMigrationPageWithRealIndexes(page: Page): Promise<void> {
	requireRealAlgoliaCredentials();
	await openMigrationPage(page);
	await submitCredentialsAndListIndexes(page, REAL_ALGOLIA_APP_ID, REAL_ALGOLIA_API_KEY);
	skipWhenNoActiveDeployment(await getMigrationErrorText(page), 'success-path');
}

async function getMigrationErrorText(page: Page): Promise<string> {
	const migrationError = page.getByTestId('migration-error');
	if ((await migrationError.count()) === 0) {
		return '';
	}

	return ((await migrationError.textContent()) ?? '').trim();
}

test.describe('Migration recovery page', () => {
	test.describe.configure({ retries: 0 });

	test('bad credentials show a visible non-empty migration error', async ({ page }) => {
		await openMigrationPage(page);
		await submitCredentialsAndListIndexes(
			page,
			'fake-app-id-first-attempt',
			'fake-api-key-first-attempt'
		);

		const migrationError = page.getByTestId('migration-error');
		await expect(migrationError).toBeVisible();

		const errorText = await getMigrationErrorText(page);
		skipWhenNoActiveDeployment(errorText, 'bad-credentials coverage');
		expect(errorText).not.toBe('');
	});

	test('after a bad-credentials error, the credentials form remains editable', async ({ page }) => {
		await openMigrationPage(page);
		await submitCredentialsAndListIndexes(
			page,
			'fake-app-id-editability',
			'fake-api-key-editability'
		);

		const migrationError = page.getByTestId('migration-error');
		await expect(migrationError).toBeVisible();

		const errorText = await getMigrationErrorText(page);
		skipWhenNoActiveDeployment(errorText, 'bad-credentials coverage');

		const appIdInput = page.getByLabel('App ID');
		const apiKeyInput = page.getByLabel('API Key');

		await expect(page.getByTestId('credentials-form')).toBeVisible();
		await appIdInput.fill('fake-app-id-editability-updated');
		await apiKeyInput.fill('fake-api-key-editability-updated');
		await expect(appIdInput).toHaveValue('fake-app-id-editability-updated');
		await expect(apiKeyInput).toHaveValue('fake-api-key-editability-updated');
	});

	test('second bad-credentials retry returns to one stable alert while form stays reusable', async ({
		page
	}) => {
		await openMigrationPage(page);
		await submitCredentialsAndListIndexes(page, 'fake-app-id-retry-one', 'fake-api-key-retry-one');

		const firstError = page.getByTestId('migration-error');
		await expect(firstError).toBeVisible();

		const firstErrorText = await getMigrationErrorText(page);
		skipWhenNoActiveDeployment(firstErrorText, 'bad-credentials coverage');

		await submitCredentialsAndListIndexes(page, 'fake-app-id-retry-two', 'fake-api-key-retry-two');

		const secondError = page.getByTestId('migration-error');
		await expect(secondError).toHaveCount(1);
		await expect(secondError).toBeVisible();
		await expect(page.getByTestId('credentials-form')).toBeVisible();
		await page.getByLabel('App ID').fill('fake-app-id-retry-three');
		await page.getByLabel('API Key').fill('fake-api-key-retry-three');
		await expect(page.getByLabel('App ID')).toHaveValue('fake-app-id-retry-three');
		await expect(page.getByLabel('API Key')).toHaveValue('fake-api-key-retry-three');
	});

	test('real credentials list indexes when env vars are present', async ({ page }) => {
		await openMigrationPageWithRealIndexes(page);

		await expect(page.getByTestId('index-list')).toBeVisible();
		const migrateButtons = page.getByTestId('migrate-button');
		const migrateButtonCount = await migrateButtons.count();
		// eslint-disable-next-line playwright/no-skipped-test -- source index inventory is an environment precondition
		test.skip(
			migrateButtonCount === 0,
			'Configured Algolia test app has no migratable source indexes for this test run'
		);
	});

	test('real credentials can start migration and show a task id', async ({ page }) => {
		await openMigrationPageWithRealIndexes(page);

		const migrateButtons = page.getByTestId('migrate-button');
		const migrateButtonCount = await migrateButtons.count();
		// eslint-disable-next-line playwright/no-skipped-test -- source index inventory is an environment precondition
		test.skip(
			migrateButtonCount === 0,
			'Configured Algolia test app has no migratable source indexes for this test run'
		);

		const migrateRequest = page.waitForResponse(
			(response) => response.request().method() === 'POST' && response.url().includes('?/migrate')
		);
		await migrateButtons.first().click();
		await migrateRequest;

		const migrationSuccess = page.getByTestId('migration-success');
		await expect(migrationSuccess).toBeVisible();
		await expect(migrationSuccess).toContainText('Task ID:');
		const successText = (await migrationSuccess.textContent()) ?? '';
		expect(successText).toMatch(/Task ID:\s+\S+/);
	});
});
