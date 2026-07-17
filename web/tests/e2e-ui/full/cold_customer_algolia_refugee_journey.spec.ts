/**
 * Full — Cold customer Algolia-refugee journey
 *
 * Dedicated unauthenticated staging contract for a new customer who starts from
 * public pricing, verifies signup, creates an index, uploads five Algolia-style
 * records, and confirms the first search plus nearby migration and billing paths.
 */

import type { Page } from '@playwright/test';
import { chooseFirstAvailableRegion } from '../../fixtures/create_index_form_helpers';
import { LOCAL_AUTO_VERIFIED_TOKEN_PREFIX, test, expect } from '../../fixtures/fixtures';
import { setAuthCookieForToken } from '../../fixtures/fresh_signup_remote_bootstrap';
import { MARKETING_PRICING, sharedPlanMinimumMonthlyLabel } from '../../../src/lib/pricing';
import { REMOTE_TARGET_OPT_IN_ENV } from '../../../playwright.config.contract';
import {
	SEARCH_PANEL_TEST_ID,
	SEARCH_TAB_LABEL,
	submitSearchPreviewQuery,
	waitForSearchPreviewHitsToContain,
	waitForSearchPreviewReady
} from '../../fixtures/search-preview-helpers';
import { openIndexDetailTab } from './index_detail_helpers';

test.use({ storageState: { cookies: [], origins: [] } });

const TRANSIENT_RATE_LIMIT_PATTERN = /too many requests/i;
const SESSION_EXPIRED_REASON = 'session_expired';

const ALGOLIA_REFUGEE_RECORDS = [
	{
		objectID: 'algolia_refugee_001',
		title: 'Blue Ridge trail running vest',
		category: 'Outdoor gear',
		brand: 'Northstar',
		price: 89
	},
	{
		objectID: 'algolia_refugee_002',
		title: 'Summit insulated water bottle',
		category: 'Outdoor gear',
		brand: 'Northstar',
		price: 34
	},
	{
		objectID: 'algolia_refugee_003',
		title: 'Harbor commuter backpack',
		category: 'Bags',
		brand: 'Waypoint',
		price: 118
	},
	{
		objectID: 'algolia_refugee_004',
		title: 'Cedar wool travel socks',
		category: 'Apparel',
		brand: 'Cedarline',
		price: 22
	},
	{
		objectID: 'algolia_refugee_005',
		title: 'Blue Ridge emergency blanket',
		category: 'Outdoor gear',
		brand: 'Northstar',
		price: 16
	}
] as const;

function isRemoteTargetMode(): boolean {
	return process.env[REMOTE_TARGET_OPT_IN_ENV] === '1';
}

function isSessionExpiredUrl(urlString: string): boolean {
	const currentUrl = new URL(urlString);
	return (
		currentUrl.pathname === '/login' &&
		currentUrl.searchParams.get('reason') === SESSION_EXPIRED_REASON
	);
}

function escapeRegex(value: string): string {
	return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function algoliaRecordsFilePayload(): {
	name: string;
	mimeType: string;
	buffer: Buffer;
} {
	return {
		name: 'algolia_refugee_records.json',
		mimeType: 'application/json',
		buffer: Buffer.from(JSON.stringify(ALGOLIA_REFUGEE_RECORDS, null, 2))
	};
}

function requireColdCustomerAdminKey(): void {
	// Stage 3 staging contract: operators must export E2E_ADMIN_KEY explicitly.
	// Repo-local ADMIN_KEY fallback is intentionally rejected so the journey
	// does not silently run against a stale or wrong-environment credential.
	const adminKey = process.env.E2E_ADMIN_KEY;
	if (!adminKey?.trim()) {
		throw new Error('E2E_ADMIN_KEY required for cold-customer create-index flow');
	}
}

async function arrangeVerifiedColdCustomer(params: {
	page: Page;
	signup: { name: string; email: string; password: string };
	createUser: (email: string, password: string, name: string) => Promise<{ customerId: string }>;
	setBillingPlanForCustomer: (customerId: string, plan: 'free') => Promise<unknown>;
	completeFreshSignupEmailVerification: (
		page: Page,
		email: string,
		password: string
	) => Promise<{ verificationToken: string }>;
	isFreshSignupArrangePrerequisiteFailure: (message: string) => boolean;
}): Promise<string> {
	const {
		page,
		signup,
		createUser,
		setBillingPlanForCustomer,
		completeFreshSignupEmailVerification,
		isFreshSignupArrangePrerequisiteFailure
	} = params;

	try {
		const createdUser = await createUser(signup.email, signup.password, signup.name);
		await setBillingPlanForCustomer(createdUser.customerId, 'free');
		const verification = await completeFreshSignupEmailVerification(
			page,
			signup.email,
			signup.password
		);
		return verification.verificationToken;
	} catch (error) {
		const failureMessage = error instanceof Error ? error.message : String(error);
		if (isFreshSignupArrangePrerequisiteFailure(failureMessage)) {
			throw new Error(`cold-customer signup prerequisite unavailable: ${failureMessage}`);
		}
		throw error;
	}
}

async function loginThroughCustomerForm(params: {
	page: Page;
	email: string;
	password: string;
	loginAs: (email: string, password: string) => Promise<string>;
}): Promise<void> {
	const { page, email, password, loginAs } = params;
	await expect(async () => {
		await page.goto('/login');
		await expect(page.getByRole('heading', { name: 'Log in to Flapjack Cloud' })).toBeVisible();
		await page.getByLabel('Email').fill(email);
		await page.getByLabel('Password').fill(password);
		await page.getByRole('button', { name: 'Log In' }).click();

		try {
			await expect(page).toHaveURL(/\/console/, { timeout: 20_000 });
		} catch (error) {
			const alertText =
				(await page
					.getByRole('alert')
					.textContent()
					.catch(() => null)) ?? '';
			if (!isRemoteTargetMode() || !TRANSIENT_RATE_LIMIT_PATTERN.test(alertText)) {
				throw error;
			}

			const token = await loginAs(email, password);
			await setAuthCookieForToken(page, token);
			await page.goto('/console');
			await expect(page).toHaveURL(/\/console/, { timeout: 20_000 });
		}
	}).toPass({
		intervals: [1_000, 2_000, 3_000, 5_000],
		timeout: 45_000
	});
}

async function gotoProtectedRoute(params: {
	page: Page;
	path: string;
	email: string;
	password: string;
	loginAs: (email: string, password: string) => Promise<string>;
}): Promise<void> {
	const { page, path, email, password, loginAs } = params;
	await page.goto(path);
	if (!isSessionExpiredUrl(page.url())) {
		return;
	}

	const token = await loginAs(email, password);
	await setAuthCookieForToken(page, token);
	await page.goto(path);
	if (isSessionExpiredUrl(page.url())) {
		throw new Error(`Session recovery failed for protected route ${path}`);
	}
}

async function assertPricingSurface(page: Page): Promise<void> {
	await page.goto('/pricing');
	const pricingMain = page.getByTestId('pricing-page-main');
	await expect(pricingMain).toBeVisible();
	await expect(pricingMain.getByRole('heading', { level: 1 })).toHaveText(
		'Start free, scale into Paid storage'
	);
	await expect(pricingMain).toContainText(MARKETING_PRICING.free_tier_promise);
	await expect(pricingMain).toContainText(
		new RegExp(`${MARKETING_PRICING.free_tier_mb} MB (of )?hot index storage`)
	);
	await expect(pricingMain).toContainText(
		new RegExp(
			`${escapeRegex(sharedPlanMinimumMonthlyLabel(MARKETING_PRICING.shared_minimum_spend_cents))}/month paid-plan minimum`
		)
	);
}

async function assertSignupValidationSurface(
	page: Page,
	signup: { name: string; email: string; password: string }
): Promise<void> {
	await page.goto('/signup');
	await expect(page).toHaveURL(/\/signup/);
	await expect(page.getByRole('heading', { name: 'Create your account' })).toBeVisible();
	await expect(page.getByText(MARKETING_PRICING.free_tier_promise)).toBeVisible();
	await expect(page.getByLabel('Password', { exact: true })).toBeVisible();
	await expect(page.getByLabel('Confirm Password')).toBeVisible();
	await page.getByLabel('Name').fill(signup.name);
	await page.getByLabel('Email').fill(signup.email);
	await page.getByLabel('Password', { exact: true }).fill(signup.password);
	await page.getByLabel('Confirm Password').fill(`${signup.password}x`);
	await page.getByRole('button', { name: 'Sign Up' }).click();
	await expect(page.getByRole('alert')).toHaveText('Passwords do not match', {
		timeout: 5_000
	});
	await expect(page).toHaveURL(/\/signup/);
}

async function assertVerificationReplay(page: Page, verificationToken: string): Promise<void> {
	if (isRemoteTargetMode() || verificationToken.startsWith(LOCAL_AUTO_VERIFIED_TOKEN_PREFIX)) {
		await page.goto(`/verify-email/${verificationToken}`);
		await expect(
			page.getByRole('heading', { name: /^(We could not verify your email|Verification Failed)$/ })
		).toBeVisible({ timeout: 10_000 });
		await expect(
			page.getByTestId('verify-result').getByText('invalid or expired verification token')
		).toBeVisible();
		return;
	}

	await expect(page.getByRole('heading', { name: 'Email verified' })).toBeVisible();
	await expect(page.getByRole('link', { name: 'Log in to continue' })).toHaveAttribute(
		'href',
		'/login'
	);
}

async function createIndexThroughConsole(params: {
	page: Page;
	indexName: string;
	ensureLocalSharedVmInventory: (region: string) => Promise<void>;
	testRegion: string;
}): Promise<void> {
	const { page, indexName, ensureLocalSharedVmInventory, testRegion } = params;
	await page.goto('/console/indexes');
	await expect(page.getByRole('heading', { name: 'Indexes' })).toBeVisible();
	await expect(async () => {
		await page.getByRole('button', { name: 'Create Index' }).click();
		await expect(
			page
				.getByTestId('create-index-form')
				.or(page.getByRole('heading', { name: 'Create a new index' }))
				.first()
		).toBeVisible({ timeout: 1_000 });
	}).toPass({ intervals: [500, 1_000, 2_000], timeout: 10_000 });

	const createForm = page.getByTestId('create-index-form');
	await expect(createForm).toBeVisible();
	await expect(createForm.getByRole('radio', { name: 'Empty index' })).toBeChecked();
	await createForm.getByLabel('Index name').fill(indexName);
	const selectedRegion = (await chooseFirstAvailableRegion(page)) || testRegion;
	await ensureLocalSharedVmInventory(selectedRegion);
	await page.getByRole('button', { name: 'Create', exact: true }).click();

	await expect(page).toHaveURL(new RegExp(`/console/indexes/${encodeURIComponent(indexName)}$`), {
		timeout: 30_000
	});
	await expect(page.getByRole('heading', { name: indexName })).toBeVisible({
		timeout: 30_000
	});
	await expect(page.getByText('Index ready — try Search')).toHaveCount(0);
	await expect(page.getByRole('button', { name: 'Open Search' })).toHaveCount(0);
	await expect(page.getByRole('tab', { name: SEARCH_TAB_LABEL })).toBeVisible();
}

async function uploadFiveAlgoliaRecords(page: Page): Promise<void> {
	const documents = await openIndexDetailTab(page, 'Documents', 'documents-section');
	await expect(documents.getByText('Upload JSON or CSV records')).toBeVisible();
	await documents.getByLabel('Upload JSON or CSV file').setInputFiles(algoliaRecordsFilePayload());
	await expect(documents.getByText('Parsed records: 5')).toBeVisible();
	await expect(documents.getByText('algolia_refugee_001')).toBeVisible();
	await documents.getByRole('button', { name: 'Upload Records' }).click();

	await expect(page.getByTestId('shared-toast-mount').getByText('Documents uploaded.')).toBeVisible(
		{
			timeout: 30_000
		}
	);
	await expect(documents.getByText('Documents uploaded.')).toHaveCount(0);
	await expect(documents.getByText('algolia_refugee_001')).toBeVisible();
	await expect(documents.getByText('Blue Ridge trail running vest')).toBeVisible();
}

async function assertFirstSearchFindsUploadedRecord(page: Page): Promise<void> {
	await openIndexDetailTab(page, SEARCH_TAB_LABEL, SEARCH_PANEL_TEST_ID);
	await waitForSearchPreviewReady(page);
	await submitSearchPreviewQuery(page, 'Blue Ridge');
	await waitForSearchPreviewHitsToContain(page, 'Blue Ridge trail running vest', 45_000);
}

async function assertAdjacentCustomerSurfaces(params: {
	page: Page;
	email: string;
	password: string;
	loginAs: (email: string, password: string) => Promise<string>;
}): Promise<void> {
	const { page, email, password, loginAs } = params;
	await gotoProtectedRoute({ page, path: '/console/migrate', email, password, loginAs });
	await expect(
		page.getByRole('heading', { name: 'Migrate from Algolia', exact: true })
	).toBeVisible();
	await expect(page.getByLabel('App ID')).toBeVisible();
	await expect(page.getByLabel('API Key')).toBeVisible();

	await gotoProtectedRoute({ page, path: '/console/billing', email, password, loginAs });
	await expect(page.getByRole('heading', { name: 'Billing' })).toBeVisible();
	await expect(
		page
			.getByRole('heading', { name: 'Payment methods', exact: true })
			.or(page.getByText('Payment method management unavailable'))
	).toBeVisible();
	await expect(
		page
			.getByRole('link', { name: 'Contact support@flapjack.foo to cancel', exact: true })
			.or(page.getByText('Payment method management is disabled.'))
	).toBeVisible();

	await assertPricingSurface(page);
}

test.describe('Cold customer Algolia-refugee journey', () => {
	test('public pricing to first uploaded-record search stays coherent on staging', async ({
		page,
		createFreshSignupIdentity,
		createUser,
		completeFreshSignupEmailVerification,
		setBillingPlanForCustomer,
		registerIndexForCleanup,
		ensureLocalSharedVmInventory,
		testRegion,
		isFreshSignupArrangePrerequisiteFailure,
		loginAs
	}) => {
		test.setTimeout(240_000);

		requireColdCustomerAdminKey();
		const signup = createFreshSignupIdentity();
		const indexName = `cold-customer-${Date.now()}`;

		await page.context().clearCookies();
		await assertPricingSurface(page);
		await assertSignupValidationSurface(page, signup);

		const verificationToken = await arrangeVerifiedColdCustomer({
			page,
			signup,
			createUser,
			setBillingPlanForCustomer,
			completeFreshSignupEmailVerification,
			isFreshSignupArrangePrerequisiteFailure
		});

		await assertVerificationReplay(page, verificationToken);
		await loginThroughCustomerForm({
			page,
			email: signup.email,
			password: signup.password,
			loginAs
		});
		await expect(page.getByRole('heading', { name: 'Console' })).toBeVisible();

		await createIndexThroughConsole({
			page,
			indexName,
			ensureLocalSharedVmInventory,
			testRegion
		});
		registerIndexForCleanup(indexName);

		await uploadFiveAlgoliaRecords(page);
		await assertFirstSearchFindsUploadedRecord(page);
		await assertAdjacentCustomerSurfaces({
			page,
			email: signup.email,
			password: signup.password,
			loginAs
		});
	});
});
