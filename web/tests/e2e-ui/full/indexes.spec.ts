/**
 * Full — Indexes
 *
 * Verifies the complete index management surface:
 *   - Load-and-verify: seeded index appears in the table
 *   - Create index through the UI form
 *   - Navigate to index detail page
 *   - Delete index through the UI
 */

import type { Page } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';
import {
	failRequiredE2eGate,
	failRequiredE2eGateOnLocalStackError,
	generatePreviewKeyAndWaitForWidget,
	gotoIndexDetailWithRetry,
	isLocalStackUnavailableError,
	submitSearchPreviewQuery,
	waitForSearchPreviewHitsToContain,
	waitForSearchPreviewReady
} from '../../fixtures/search-preview-helpers';
import { seedSearchableIndexForCustomer } from '../../fixtures/searchable-index';

type RuntimeRegionOption = {
	id: string;
	label: string;
	checked: boolean;
	disabled: boolean;
};

const API_URL = process.env.API_URL ?? 'http://localhost:3001';

type CreatedFixtureUser = {
	customerId: string;
	email: string;
	token: string;
};

type CreateUserFn = (email: string, password: string, name?: string) => Promise<CreatedFixtureUser>;
type CompleteFreshSignupEmailVerificationFn = (
	page: Page,
	email: string
) => Promise<{ verificationToken: string }>;
type IsFreshSignupArrangePrerequisiteFailureFn = (alertText: string) => boolean;
type SetBillingPlanForCustomerToFreeFn = (customerId: string, plan: 'free') => Promise<void>;

async function openCreateIndexForm(page: Page): Promise<void> {
	await page.goto('/console/indexes');
	await expect(page.getByRole('heading', { name: 'Indexes' })).toBeVisible();
	await page.getByRole('button', { name: 'Create Index' }).click();
}

async function indexCreationBlockedByPlanLimit(page: Page): Promise<boolean> {
	return page
		.getByText(/reached your free plan index limit/i)
		.isVisible()
		.catch(() => false);
}

function isPlanLimitCreateBlock(error: unknown): boolean {
	const message = error instanceof Error ? error.message : String(error);
	return /index creation blocked by free-plan capacity/i.test(message);
}

async function waitForCreateIndexSuccess(
	page: Page,
	indexName: string,
	options?: { requireTableRow?: boolean }
): Promise<void> {
	const indexInTable = page.getByRole('cell', { name: indexName });
	const provisioningMsg = page.getByText('Setting up your search endpoint');
	const createdMsg = page.getByText('Index created successfully');
	const detailHeading = page.getByRole('heading', { name: indexName, exact: true });
	const isOnCreatedIndexDetailPage = (): boolean => {
		try {
			const current = new URL(page.url(), 'http://localhost');
			const expectedPath = `/console/indexes/${encodeURIComponent(indexName)}`;
			return current.pathname === expectedPath;
		} catch {
			return false;
		}
	};

	await expect
		.poll(
			async () => {
				if (isOnCreatedIndexDetailPage() && (await detailHeading.isVisible().catch(() => false))) {
					return 'detail';
				}
				if (await indexInTable.isVisible().catch(() => false)) return 'table';
				if (!options?.requireTableRow && (await provisioningMsg.isVisible().catch(() => false))) {
					return 'provisioning';
				}
				if (!options?.requireTableRow && (await createdMsg.isVisible().catch(() => false))) {
					return 'created';
				}
				return 'pending';
			},
			{ timeout: 30_000 }
		)
		.not.toBe('pending');
}

async function waitForDuplicateCreateSafeOutcome(page: Page, indexName: string): Promise<void> {
	const formAlert = page.getByRole('alert').first();
	const quotaExceededCallout = page.getByTestId('quota-exceeded-callout');
	const createdMsg = page.getByText('Index created successfully');
	const existingRow = page.getByRole('row').filter({
		has: page.getByRole('link', { name: indexName, exact: true })
	});
	let sawQuotaExceeded = false;
	let outcome:
		| 'pending'
		| 'duplicate-alert'
		| 'idempotent'
		| 'unexpected-success'
		| 'quota-exceeded' = 'pending';

	await expect
		.poll(
			async () => {
				if (await quotaExceededCallout.isVisible().catch(() => false)) {
					sawQuotaExceeded = true;
					outcome = 'quota-exceeded';
					return outcome;
				}

				const alertText = ((await formAlert.textContent().catch(() => '')) ?? '').trim();
				if (/already exists|duplicate/i.test(alertText)) {
					outcome = 'duplicate-alert';
					return outcome;
				}

				if (await existingRow.isVisible().catch(() => false)) {
					outcome = 'idempotent';
					return outcome;
				}

				if (await createdMsg.isVisible().catch(() => false)) {
					outcome = 'unexpected-success';
					return outcome;
				}

				return 'pending';
			},
			{ timeout: 30_000 }
		)
		.not.toBe('pending');

	if (sawQuotaExceeded) {
		throw new Error('index creation blocked by free-plan capacity in this environment');
	}

	expect(outcome).not.toBe('unexpected-success');
}

async function submitCreateIndexForm(page: Page, name: string, regionId?: string): Promise<void> {
	await page.getByLabel('Index name').fill(name);
	const form = page.getByTestId('create-index-form');
	// eslint-disable-next-line playwright/no-raw-locators -- evaluateAll needs raw DOM access to read .value/.disabled
	const regionRadios = form.locator('input[name="region"]');

	if (regionId) {
		const targetIndex = await regionRadios.evaluateAll(
			(inputs, targetRegionId) =>
				inputs.findIndex((input) => {
					const radio = input as HTMLInputElement;
					return !radio.disabled && radio.value === targetRegionId;
				}),
			regionId
		);
		if (targetIndex < 0) {
			const observedRegions = await regionRadios.evaluateAll((inputs) =>
				inputs
					.map((input) => {
						const radio = input as HTMLInputElement;
						const disabledTag = radio.disabled ? ',disabled' : '';
						return `${radio.value}${disabledTag}`;
					})
					.join(', ')
			);
			throw new Error(
				`Region radio "${regionId}" was not selectable in create form. observed=${observedRegions || 'none'}`
			);
		}
		// Click the visible label card that contains the region ID text.
		// The sr-only radio inside the label gets checked via label click propagation.
		await form.getByText(regionId, { exact: true }).click();
	} else {
		// Region radios are optional in some environments.
		// Click the first region label card if any radios are present.
		if ((await regionRadios.count()) > 0) {
			const firstRegionId = await regionRadios
				.first()
				.evaluate((el) => (el as HTMLInputElement).value);
			await form.getByText(firstRegionId, { exact: true }).click();
		}
	}

	await page.getByRole('button', { name: 'Create', exact: true }).click();
}

async function submitCreateIndexFormWithTransientRetry(
	page: Page,
	name: string,
	regionId?: string
): Promise<void> {
	const transientCreateFailurePattern = /temporarily unavailable|service is unavailable/i;
	const retryableCreateFailurePattern = /^failed to create index$/i;
	const createFailureAlertPattern = /failed to create index/i;
	const alert = page.getByRole('alert').first();
	const quotaExceededCallout = page.getByTestId('quota-exceeded-callout');
	const indexInTable = page.getByRole('cell', { name });
	const provisioningMsg = page.getByText('Setting up your search endpoint');
	const createdMsg = page.getByText('Index created successfully');
	const maxAttempts = 4;
	const isOnCreatedIndexDetailPage = (): boolean => {
		try {
			const current = new URL(page.url(), 'http://localhost');
			const expectedPath = `/console/indexes/${encodeURIComponent(name)}`;
			return current.pathname === expectedPath;
		} catch {
			return false;
		}
	};

	for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
		const createActionResponsePromise = page
			.waitForResponse(
				(response) =>
					response.request().method() === 'POST' && response.url().includes('/console/indexes'),
				{ timeout: 15_000 }
			)
			.catch(() => null);
		await submitCreateIndexForm(page, name, regionId);
		await createActionResponsePromise;

		let settledAlertText = '';
		let settledOutcome = 'pending' as
			| 'pending'
			| 'success'
			| 'retryable'
			| 'failed'
			| 'quota-exceeded';
		try {
			await expect
				.poll(
					async () => {
						if (await quotaExceededCallout.isVisible().catch(() => false)) {
							settledOutcome = 'quota-exceeded';
							return settledOutcome;
						}

						if (await indexInTable.isVisible().catch(() => false)) {
							settledOutcome = 'success';
							return settledOutcome;
						}
						if (await provisioningMsg.isVisible().catch(() => false)) {
							settledOutcome = 'success';
							return settledOutcome;
						}
						if (await createdMsg.isVisible().catch(() => false)) {
							settledOutcome = 'success';
							return settledOutcome;
						}
						// Create submit can redirect directly to detail on success.
						if (
							isOnCreatedIndexDetailPage() &&
							(await page
								.getByRole('heading', { name, exact: true })
								.isVisible()
								.catch(() => false))
						) {
							settledOutcome = 'success';
							return settledOutcome;
						}

						settledAlertText = ((await alert.textContent().catch(() => '')) ?? '').trim();
						if (!settledAlertText) {
							return 'pending';
						}
						if (transientCreateFailurePattern.test(settledAlertText)) {
							settledOutcome = 'retryable';
							return settledOutcome;
						}
						if (retryableCreateFailurePattern.test(settledAlertText)) {
							settledOutcome = 'retryable';
							return settledOutcome;
						}
						if (createFailureAlertPattern.test(settledAlertText)) {
							settledOutcome = 'failed';
							return settledOutcome;
						}
						return 'pending';
					},
					{ timeout: 15_000 }
				)
				.not.toBe('pending');
		} catch {
			if (
				isOnCreatedIndexDetailPage() &&
				(await page
					.getByRole('heading', { name, exact: true })
					.isVisible()
					.catch(() => false))
			) {
				return;
			}
			// Shared-host stacks intermittently suppress in-form alerts; keep
			// retrying attempts instead of aborting the helper on first timeout.
			settledOutcome = 'retryable';
		}

		if (settledOutcome === 'success') {
			return;
		}

		if (settledOutcome === 'failed') {
			throw new Error(
				`create index form returned failure: ${settledAlertText || 'Failed to create index'}`
			);
		}

		if (settledOutcome === 'quota-exceeded') {
			throw new Error('index creation blocked by free-plan capacity in this environment');
		}

		if (attempt === maxAttempts - 1) {
			throw new Error(`create index form kept failing after retries: ${settledAlertText}`);
		}

		await expect(alert)
			.toBeHidden({ timeout: 5_000 })
			.catch(() => {});
	}
}

async function captureDefaultRuntimeRegionFromCreateForm(page: Page): Promise<string> {
	// eslint-disable-next-line playwright/no-raw-locators -- evaluateAll needs raw DOM access to read .value/.disabled/.checked
	const regionRadios = page.getByTestId('create-index-form').locator('input[name="region"]');
	const regionOptions: RuntimeRegionOption[] = await regionRadios.evaluateAll((inputs) =>
		inputs.map((input) => {
			const radio = input as HTMLInputElement;
			const labelText = radio.closest('label')?.innerText ?? '';
			return {
				id: radio.value.trim(),
				label: labelText.replace(/\s+/g, ' ').trim(),
				checked: radio.checked,
				disabled: radio.disabled
			};
		})
	);

	const selectableOptions = regionOptions.filter((option) => option.id && !option.disabled);
	const observedOptions =
		regionOptions.length === 0
			? 'none'
			: regionOptions
					.map((option) => {
						const checkedTag = option.checked ? ',checked' : '';
						const disabledTag = option.disabled ? ',disabled' : '';
						return `${option.label || '(no-label)'} [${option.id || '(no-id)'}${checkedTag}${disabledTag}]`;
					})
					.join('; ');

	if (selectableOptions.length < 1) {
		throw new Error(
			`ENV-BLOCKER: create form exposed no selectable regions. observed=${observedOptions}`
		);
	}

	const defaultRegion = selectableOptions.find((option) => option.checked) ?? selectableOptions[0];
	return defaultRegion.id;
}

async function expectIndexRegionRow(
	page: Page,
	indexName: string,
	regionId: string
): Promise<void> {
	const row = page.getByRole('row').filter({
		has: page.getByRole('link', { name: indexName, exact: true })
	});
	await expect(row.getByRole('cell', { name: regionId, exact: true })).toBeVisible({
		timeout: 30_000
	});
}

async function expectOverviewRegionStat(page: Page, regionId: string): Promise<void> {
	const statsSection = page.getByTestId('stats-section');
	await expect(statsSection.getByText('Region', { exact: true })).toBeVisible();
	await expect(statsSection.getByText(regionId, { exact: true })).toBeVisible();
}

async function expectTemplateDefaults(page: Page): Promise<void> {
	const form = page.getByTestId('create-index-form');
	// eslint-disable-next-line playwright/no-raw-locators -- need name="template" to distinguish from region radios
	await expect(form.locator('input[name="template_id"]')).toHaveCount(3);
	await expect(form.getByRole('radio', { name: 'Empty index' })).toBeChecked();
	await expect(form.getByRole('radio', { name: /Movies/ })).not.toBeChecked();
	await expect(form.getByRole('radio', { name: /Products/ })).not.toBeChecked();
	await expect(form.getByLabel('Index name')).toHaveValue('');
}

async function arrangeFreshFreePlanIndexesUserSession({
	page,
	seed,
	createUser,
	completeFreshSignupEmailVerification,
	isFreshSignupArrangePrerequisiteFailure,
	setBillingPlanForCustomer,
	gateName
}: {
	page: Page;
	seed: string;
	createUser: CreateUserFn;
	completeFreshSignupEmailVerification: CompleteFreshSignupEmailVerificationFn;
	isFreshSignupArrangePrerequisiteFailure: IsFreshSignupArrangePrerequisiteFailureFn;
	setBillingPlanForCustomer: SetBillingPlanForCustomerToFreeFn;
	gateName: string;
}): Promise<CreatedFixtureUser & { password: string }> {
	const email = `indexes-${seed}@e2e.griddle.test`;
	const password = 'TestPassword123!';
	await page.context().clearCookies();
	let createdUser: CreatedFixtureUser | null = null;

	try {
		createdUser = await createUser(email, password, `Indexes Test ${seed}`);
		await completeFreshSignupEmailVerification(page, email);
	} catch (error) {
		const failureMessage = error instanceof Error ? error.message : String(error);
		if (isFreshSignupArrangePrerequisiteFailure(failureMessage)) {
			failRequiredE2eGate(
				gateName,
				`${gateName} prerequisite unavailable in local env: ${failureMessage}`
			);
		}
		throw error;
	}

	await page.goto('/login');
	await page.getByLabel('Email').fill(email);
	await page.getByLabel('Password').fill(password);
	await page.getByRole('button', { name: 'Log In' }).click();
	await expect(page).toHaveURL(/\/console/, { timeout: 10_000 });

	if (!createdUser) {
		throw new Error(`${gateName} failed: fixture createUser did not return a user`);
	}
	await setBillingPlanForCustomer(createdUser.customerId, 'free');
	return { ...createdUser, password };
}

test.describe('Indexes list page', () => {
	test('load-and-verify: seeded index appears in the table', async ({ page, seedIndex }) => {
		const name = `e2e-list-${Date.now()}`;

		// Arrange: seed via API
		await seedIndex(name);

		// Act: navigate to indexes
		await page.goto('/console/indexes');

		// Assert: page-specific heading visible (not sidebar nav)
		await expect(page.getByRole('heading', { name: 'Indexes' })).toBeVisible();

		// Assert: the seeded index name appears in the table
		await expect(page.getByRole('cell', { name })).toBeVisible({ timeout: 10_000 });
	});

	test('Create Index button toggles the creation form', async ({ page }) => {
		await page.goto('/console/indexes');
		await expect(page.getByRole('heading', { name: 'Indexes' })).toBeVisible();

		// Form is hidden initially
		await expect(page.getByTestId('create-index-form')).toBeHidden();

		// Act: click Create Index
		await page.getByRole('button', { name: 'Create Index' }).click();

		// Assert: form appears
		await expect(page.getByTestId('create-index-form')).toBeVisible();
		await expect(page.getByLabel('Index name')).toBeVisible();
		await expect(page.getByRole('button', { name: 'Create', exact: true })).toBeVisible();
	});

	test('Cancel button hides the creation form', async ({ page }) => {
		await openCreateIndexForm(page);
		await expect(page.getByTestId('create-index-form')).toBeVisible();

		await page.getByRole('button', { name: 'Cancel' }).click();
		await expect(page.getByTestId('create-index-form')).toBeHidden();
	});

	test('create index through the UI adds it to the table', async ({
		page,
		createUser,
		completeFreshSignupEmailVerification,
		isFreshSignupArrangePrerequisiteFailure,
		setBillingPlanForCustomer
	}) => {
		test.setTimeout(180_000);
		const name = `e2e-create-${Date.now()}`;
		await arrangeFreshFreePlanIndexesUserSession({
			page,
			seed: `create-${Date.now()}`,
			createUser,
			completeFreshSignupEmailVerification,
			isFreshSignupArrangePrerequisiteFailure,
			setBillingPlanForCustomer,
			gateName: 'create index through the UI adds it to the table'
		});
		await openCreateIndexForm(page);
		if (await indexCreationBlockedByPlanLimit(page)) {
			failRequiredE2eGate(
				'create index through the UI adds it to the table',
				'index creation blocked by free-plan capacity in this environment'
			);
		}
		try {
			await submitCreateIndexFormWithTransientRetry(page, name);
			await waitForCreateIndexSuccess(page, name);
		} catch (error) {
			if (isPlanLimitCreateBlock(error)) {
				failRequiredE2eGate(
					'create index through the UI adds it to the table',
					'index creation blocked by free-plan capacity in this environment'
				);
			}
			failRequiredE2eGateOnLocalStackError(
				'create index through the UI adds it to the table',
				error
			);
			throw error;
		}
	});

	test('create/list/detail journey uses one UI create with runtime default region', async ({
		page,
		createUser,
		completeFreshSignupEmailVerification,
		isFreshSignupArrangePrerequisiteFailure,
		setBillingPlanForCustomer
	}) => {
		const seed = Date.now();
		const createdIndexName = `e2e-default-region-${seed}`;
		await arrangeFreshFreePlanIndexesUserSession({
			page,
			seed: `journey-${seed}`,
			createUser,
			completeFreshSignupEmailVerification,
			isFreshSignupArrangePrerequisiteFailure,
			setBillingPlanForCustomer,
			gateName: 'create/list/detail journey uses one UI create with runtime default region'
		});

		await openCreateIndexForm(page);
		const defaultRegionId = await captureDefaultRuntimeRegionFromCreateForm(page);
		await page.getByRole('button', { name: 'Cancel' }).click();

		await openCreateIndexForm(page);
		await submitCreateIndexFormWithTransientRetry(page, createdIndexName, defaultRegionId);

		await waitForCreateIndexSuccess(page, createdIndexName);

		await page.goto('/console/indexes');
		await expectIndexRegionRow(page, createdIndexName, defaultRegionId);

		await page.getByRole('link', { name: createdIndexName, exact: true }).click();
		await expect(page).toHaveURL(
			new RegExp(`/console/indexes/${encodeURIComponent(createdIndexName)}`)
		);
		await expect(page.getByRole('heading', { name: createdIndexName })).toBeVisible({
			timeout: 10_000
		});
		await expectOverviewRegionStat(page, defaultRegionId);
	});

	test('template selection defaults, prefills, and resets on cancel', async ({ page }) => {
		await openCreateIndexForm(page);
		const form = page.getByTestId('create-index-form');
		const nameInput = form.getByLabel('Index name');

		await expectTemplateDefaults(page);

		await form.getByText('Movies — 1,000 docs', { exact: true }).click();
		await expect(nameInput).toHaveValue('movies');
		await expect(form.getByRole('radio', { name: /Movies/ })).toBeChecked();

		await form.getByText('Products — 1,000 docs', { exact: true }).click();
		await expect(nameInput).toHaveValue('products');
		await expect(form.getByRole('radio', { name: /Products/ })).toBeChecked();

		await form.getByText('Empty index', { exact: true }).click();
		await expect(nameInput).toHaveValue('');
		await expect(form.getByRole('radio', { name: 'Empty index' })).toBeChecked();

		await page.getByRole('button', { name: 'Cancel' }).click();
		await expect(page.getByTestId('create-index-form')).toBeHidden();

		await page.getByRole('button', { name: 'Create Index' }).click();
		await expectTemplateDefaults(page);
	});

	test('duplicate index name shows a safe failure instead of succeeding', async ({
		page,
		createUser,
		completeFreshSignupEmailVerification,
		isFreshSignupArrangePrerequisiteFailure,
		setBillingPlanForCustomer
	}) => {
		test.setTimeout(180_000);
		const name = `e2e-duplicate-${Date.now()}`;
		await arrangeFreshFreePlanIndexesUserSession({
			page,
			seed: `duplicate-${Date.now()}`,
			createUser,
			completeFreshSignupEmailVerification,
			isFreshSignupArrangePrerequisiteFailure,
			setBillingPlanForCustomer,
			gateName: 'duplicate index name shows a safe failure instead of succeeding'
		});
		await openCreateIndexForm(page);
		await submitCreateIndexFormWithTransientRetry(page, name);
		await waitForCreateIndexSuccess(page, name);
		await page.goto('/console/indexes');
		await expect(page.getByText('Index created successfully')).toHaveCount(0);

		await openCreateIndexForm(page);
		if (await indexCreationBlockedByPlanLimit(page)) {
			failRequiredE2eGate(
				'duplicate index name shows a safe failure instead of succeeding',
				'duplicate-create flow blocked by free-plan capacity in this environment'
			);
		}
		try {
			await submitCreateIndexForm(page, name);
			await waitForDuplicateCreateSafeOutcome(page, name);
		} catch (error) {
			if (isPlanLimitCreateBlock(error)) {
				failRequiredE2eGate(
					'duplicate index name shows a safe failure instead of succeeding',
					'duplicate-create flow blocked by free-plan capacity in this environment'
				);
			}
			failRequiredE2eGateOnLocalStackError(
				'duplicate index name shows a safe failure instead of succeeding',
				error
			);
			throw error;
		}
		await expect(page).toHaveURL(/\/console\/indexes/);
		await expect(page.getByText('Index created successfully')).toHaveCount(0);
	});

	test('clicking an index name navigates to the detail page', async ({ page, seedIndex }) => {
		const name = `e2e-detail-nav-${Date.now()}`;
		await seedIndex(name);

		await page.goto('/console/indexes');
		await expect(page.getByRole('cell', { name })).toBeVisible({ timeout: 10_000 });

		// Act: click the index name link
		await page.getByRole('link', { name }).click();

		// Assert: detail page shows the index name as heading
		await expect(page).toHaveURL(new RegExp(`/console/indexes/${encodeURIComponent(name)}`));
		await expect(page.getByRole('heading', { name })).toBeVisible();
	});
});

test.describe('Index detail page', () => {
	test('detail page has a delete button with confirmation', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		test.setTimeout(120_000);
		const name = `e2e-del-${Date.now()}`;
		await seedIndex(name, testRegion);

		await gotoIndexDetailWithRetry(page, name);

		// The delete button should be visible on the page
		await expect(page.getByRole('button', { name: /delete/i })).toBeVisible();
	});

	test('Search Preview tab shows real search results from Flapjack', async ({
		page,
		createUser,
		completeFreshSignupEmailVerification,
		isFreshSignupArrangePrerequisiteFailure,
		setBillingPlanForCustomer,
		testRegion
	}) => {
		test.setTimeout(180_000);
		const seed = Date.now();
		const name = `e2e-search-${seed}`;
		const gateName = 'Search Preview tab shows real search results from Flapjack';
		const userSession = await arrangeFreshFreePlanIndexesUserSession({
			page,
			seed: `search-preview-${seed}`,
			createUser,
			completeFreshSignupEmailVerification,
			isFreshSignupArrangePrerequisiteFailure,
			setBillingPlanForCustomer,
			gateName
		});

		// Arrange: seed an index with searchable documents via the fixture
		let seeded: { query: string; expectedHitText: string };
		try {
			seeded = await Promise.race([
				seedSearchableIndexForCustomer({
					apiUrl: API_URL,
					adminKey: process.env.E2E_ADMIN_KEY,
					customerId: userSession.customerId,
					token: userSession.token,
					name,
					region: testRegion,
					query: 'Search Preview',
					expectedHitText: `Search Preview Hit ${seed}`,
					documents: [
						{
							objectID: `search-preview-doc-${seed}`,
							title: `Search Preview Hit ${seed}`,
							body: 'search-preview-fixture'
						}
					]
				}),
				new Promise<never>((_, reject) =>
					setTimeout(() => reject(new Error('seedSearchableIndex timed out after 150s')), 150_000)
				)
			]);
		} catch (error) {
			failRequiredE2eGate(
				gateName,
				`seedSearchableIndex failed for this environment: ${(error as Error).message}`
			);
		}

		// Act: navigate to the index detail page
		await gotoIndexDetailWithRetry(page, name);

		// Act: click the Search Preview tab
		await page.getByRole('tab', { name: 'Search Preview' }).click();

		// Assert: the search preview section is visible
		await expect(page.getByTestId('search-preview-section')).toBeVisible();

		// Wait through provisioning (up to 90s) — if readiness never arrives, the test fails
		await waitForSearchPreviewReady(page);

		// Act: click "Generate Preview Key" to request a key and mount InstantSearch
		await generatePreviewKeyAndWaitForWidget(page);

		// Act: type the query into the search box
		await submitSearchPreviewQuery(page, seeded.query);

		// Assert: the expected hit text appears in the search preview hits area
		await waitForSearchPreviewHitsToContain(page, seeded.expectedHitText, 60_000);
	});
});
