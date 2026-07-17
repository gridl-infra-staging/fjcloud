/**
 * Full — First five minutes customer polish
 *
 * Retains the Stage 1-4 customer journey in one browser owner: API-host
 * landing, public web pricing/signup contracts, fresh-account verification,
 * first console entry, create-index redirect, and first-click zero-data tabs.
 */

import { chooseFirstAvailableRegion } from '../../fixtures/create_index_form_helpers';
import { LOCAL_AUTO_VERIFIED_TOKEN_PREFIX, test, expect } from '../../fixtures/fixtures';
import { MARKETING_PRICING, sharedPlanMinimumMonthlyLabel } from '../../../src/lib/pricing';
import { REMOTE_TARGET_OPT_IN_ENV } from '../../../playwright.config.contract';
import { SEARCH_TAB_LABEL, SEARCH_TAB_QUERY_VALUE } from '../../fixtures/search-preview-helpers';
import { openIndexDetailTab } from './index_detail_helpers';

test.use({ storageState: { cookies: [], origins: [] } });

test.describe('First five minutes customer journey', () => {
	test('public entry, verified signup, create-index redirect, and first-click tabs stay coherent', async ({
		page,
		apiUrl,
		createFreshSignupIdentity,
		createUser,
		completeFreshSignupEmailVerification,
		setBillingPlanForCustomer,
		registerIndexForCleanup,
		ensureLocalSharedVmInventory,
		testRegion,
		isFreshSignupArrangePrerequisiteFailure
	}) => {
		test.setTimeout(180_000);

		const adminKey = process.env.E2E_ADMIN_KEY ?? process.env.ADMIN_KEY;
		if (!adminKey?.trim()) {
			test.skip(true, 'E2E_ADMIN_KEY required for first-five-minutes create-index flow');
			return;
		}

		const signup = createFreshSignupIdentity();
		const createdIndexName = `first-five-${Date.now()}`;

		await page.context().clearCookies();

		await page.goto(apiUrl);
		await expect(page).toHaveURL(
			new RegExp(`^${apiUrl.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}/?$`)
		);
		await expect(page.getByRole('heading', { name: 'Flapjack Cloud', level: 1 })).toBeVisible();
		await expect(page.getByRole('link', { name: 'Log in' })).toHaveAttribute(
			'href',
			'https://cloud.flapjack.foo/login'
		);
		// API-host root is owned by infra/api; this CTA absence is deliberately out of lane.
		await expect(page.getByRole('link', { name: /sign up|get started/i })).toHaveCount(0);

		await page.goto('/');
		await expect(page).toHaveURL(/\/login/);
		await expect(page.getByRole('heading', { name: 'Log in to Flapjack Cloud' })).toBeVisible();
		await expect(page.getByTestId('public-beta-banner')).toHaveCount(0);

		await page.goto('/pricing');
		const pricingMain = page.getByTestId('pricing-page-main');
		await expect(pricingMain).toBeVisible();
		await expect(
			page.getByRole('heading', { name: 'Start free, scale into paid storage' })
		).toBeVisible();
		await expect(pricingMain).toContainText(MARKETING_PRICING.free_tier_promise);
		await expect(pricingMain).toContainText(
			`Your free tier includes ${MARKETING_PRICING.free_tier_mb} MB of hot index storage before paid billing starts.`
		);
		await expect(pricingMain).toContainText(
			`Paid accounts have a ${sharedPlanMinimumMonthlyLabel(MARKETING_PRICING.shared_minimum_spend_cents)}/month paid-plan minimum`
		);
		await expect(page.getByTestId('public-beta-banner')).toContainText(/public beta/i);

		await page.goto('/signup');
		await expect(page).toHaveURL(/\/signup/);
		await expect(page.getByRole('heading', { name: 'Create your account' })).toBeVisible();
		await expect(page.getByText('Use at least 8 characters.')).toBeVisible();
		await page.getByLabel('Name').fill(signup.name);
		await page.getByLabel('Email').fill(signup.email);
		await page.getByLabel('Password', { exact: true }).fill(signup.password);
		await page.getByLabel('Confirm Password').fill(`${signup.password}x`);
		await page.getByRole('button', { name: 'Sign Up' }).click();
		await expect(page.getByRole('alert')).toHaveText('Passwords do not match', {
			timeout: 5_000
		});
		await expect(page).toHaveURL(/\/signup/);

		let verificationToken: string;
		try {
			const createdUser = await createUser(signup.email, signup.password, signup.name);
			await setBillingPlanForCustomer(createdUser.customerId, 'free');
			const verification = await completeFreshSignupEmailVerification(
				page,
				signup.email,
				signup.password
			);
			verificationToken = verification.verificationToken;
		} catch (error) {
			const failureMessage = error instanceof Error ? error.message : String(error);
			if (isFreshSignupArrangePrerequisiteFailure(failureMessage)) {
				test.skip(true, `first-five-minutes signup prerequisite unavailable: ${failureMessage}`);
				return;
			}
			throw error;
		}

		if (
			process.env[REMOTE_TARGET_OPT_IN_ENV] === '1' ||
			verificationToken.startsWith(LOCAL_AUTO_VERIFIED_TOKEN_PREFIX)
		) {
			await page.goto(`/verify-email/${verificationToken}`);
			await expect(
				page.getByRole('heading', { name: 'We could not verify your email' })
			).toBeVisible({ timeout: 10_000 });
		} else {
			await expect(page.getByRole('heading', { name: 'Email verified' })).toBeVisible();
			await expect(page.getByRole('link', { name: 'Log in to continue' })).toHaveAttribute(
				'href',
				'/login'
			);
		}

		await page.goto('/login');
		await page.getByLabel('Email').fill(signup.email);
		await page.getByLabel('Password').fill(signup.password);
		await page.getByRole('button', { name: 'Log In' }).click();
		await expect(page).toHaveURL(/\/console/, { timeout: 10_000 });

		await expect(page.getByRole('heading', { name: 'Console' })).toBeVisible();
		await expect(page.getByTestId('onboarding-banner')).toBeVisible();
		await page
			.getByTestId('onboarding-banner')
			.getByRole('link', { name: 'Continue setup' })
			.click();
		await expect(page).toHaveURL(/\/console\/onboarding/);
		await expect(page.getByTestId('onboarding-step-1')).toBeVisible();
		await expect(page.getByRole('heading', { name: 'Get Started' })).toBeVisible();

		await page.goto('/console/indexes');
		await expect(page.getByRole('heading', { name: 'Indexes' })).toBeVisible();
		await page.getByRole('button', { name: 'Create Index' }).click();
		const createForm = page.getByTestId('create-index-form');
		await expect(createForm).toBeVisible();
		await expect(createForm.getByRole('radio', { name: 'Empty index' })).toBeChecked();
		await createForm.getByLabel('Index name').fill(createdIndexName);
		const selectedRegion = (await chooseFirstAvailableRegion(page)) || testRegion;
		await ensureLocalSharedVmInventory(selectedRegion);
		await page.getByRole('button', { name: 'Create', exact: true }).click();
		registerIndexForCleanup(createdIndexName);

		await expect(page).toHaveURL(
			new RegExp(`/console/indexes/${encodeURIComponent(createdIndexName)}$`),
			{ timeout: 30_000 }
		);
		await expect(page.getByRole('heading', { name: createdIndexName })).toBeVisible({
			timeout: 30_000
		});
		await expect(page.getByRole('button', { name: 'Open Search' })).toHaveCount(0);
		await page.getByRole('tab', { name: SEARCH_TAB_LABEL }).click();
		const searchUrl = new URL(page.url());
		expect(searchUrl.searchParams.get('tab')).toBe(SEARCH_TAB_QUERY_VALUE);

		const documents = await openIndexDetailTab(page, 'Documents', 'documents-section');
		await expect(documents.getByText('Upload JSON or CSV file')).toBeVisible();
		await expect(documents.getByRole('button', { name: 'Upload Records' })).toBeDisabled();
		await expect(documents.getByLabel('Record JSON')).toBeVisible();
		await expect(documents.getByRole('button', { name: 'Browse Documents' })).toHaveCount(0);

		const merchandising = await openIndexDetailTab(page, 'Merchandising', 'merchandising-section');
		await expect(merchandising.getByRole('heading', { name: 'Merchandising hub' })).toBeVisible();
		await expect(
			merchandising.getByRole('button', { name: '+ New rule', exact: true })
		).toBeVisible();

		const synonyms = await openIndexDetailTab(page, 'Synonyms', 'synonyms-section');
		await expect(synonyms.getByRole('heading', { name: 'Synonyms' })).toBeVisible();
		await expect(synonyms.getByText('No synonyms yet')).toBeVisible();
		await expect(synonyms.getByRole('button', { name: 'Add Synonym' })).toBeVisible();

		await expect(page.getByRole('tab', { name: 'Metrics', exact: true })).toBeVisible();
		const metrics = await openIndexDetailTab(page, 'Metrics', 'metrics-tab-panel');
		await expect(metrics).toBeVisible();
		await expect(page.getByRole('tab', { name: 'Metrics', exact: true })).toHaveAttribute(
			'aria-selected',
			'true'
		);
	});
});
