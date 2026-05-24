/**
 * Full — Public Pages
 *
 * Verifies pages that are accessible without authentication:
 *   - Landing page (/)
 *   - Public beta page (/beta)
 *   - Legal pages (/terms, /privacy, /dpa)
 *   - Public error boundary (missing routes)
 *   - Status page (/status)
 *
 * These tests do not use stored auth state.
 */

import { test, expect } from '../../fixtures/fixtures';
import {
	MARKETING_PRICING,
	pricingContractSnapshotFromMarketing,
	sharedPlanMinimumMonthlyLabel
} from '../../../src/lib/pricing';
import { assertSharedLegalPageContract } from '../../fixtures/legal_page_playwright_helpers';

// Unauthenticated — no stored auth state needed
test.use({ storageState: { cookies: [], origins: [] } });

test.describe('Landing page', () => {
	test('load-and-verify: root redirects unauthenticated users to /login', async ({ page }) => {
		await page.goto('/');

		await expect(page).toHaveTitle(/Flapjack Cloud/);
		await expect(page).not.toHaveTitle(/Griddle/);
		await expect(page).toHaveURL(/\/login$/);
		await expect(page.getByRole('heading', { name: 'Log in to Flapjack Cloud' })).toBeVisible();
		await expect(page.getByRole('main')).not.toContainText('What you get');
	});

	test('pricing header uses Log in copy and reaches /login', async ({ page }) => {
		await page.goto('/pricing');

		await page.getByRole('navigation').getByRole('link', { name: 'Log in' }).click();
		await expect(page).toHaveURL(/\/login/);
		await expect(page).toHaveTitle(/Flapjack Cloud/);
		await expect(page).not.toHaveTitle(/Griddle/);
		await expect(page.getByRole('heading', { name: 'Log in to Flapjack Cloud' })).toBeVisible();
	});

	// URL-obscurity beta gate: public Sign Up CTAs removed, but /signup itself
	// stays reachable so invited users can register via the direct URL.
	// See docs/decisions/2026_05_23_beta_signup_gate.md.
	test('direct navigation to /signup still renders the signup form', async ({ page }) => {
		await page.goto('/signup');
		await expect(page).toHaveURL(/\/signup/);
		await expect(page.getByRole('heading', { name: 'Create your account' })).toBeVisible();
	});

});

test.describe('Pricing page', () => {
	test('renders pricing-first copy and public links for unauthenticated users', async ({ page }) => {
		await page.goto('/pricing');
		const pricingMain = page.getByTestId('pricing-page-main');
		const marketingSnapshot = pricingContractSnapshotFromMarketing(MARKETING_PRICING);

		await expect(pricingMain).toBeVisible();
		await expect(pricingMain).not.toContainText(/Page not found|Not found/i);
		await expect(page.getByRole('heading', { name: /pricing/i })).toBeVisible();
		await expect(pricingMain).toContainText(MARKETING_PRICING.free_tier_promise);
		await expect(pricingMain).toContainText(`${MARKETING_PRICING.free_tier_mb} MB`);
		await expect(pricingMain).toContainText(
			`${MARKETING_PRICING.free_tier_searches_per_month.toLocaleString('en-US')} searches/month`
		);
		await expect(pricingMain).toContainText('Hot index storage');
		await expect(pricingMain).toContainText('Cold snapshot storage');
		await expect(pricingMain).toContainText('$5/month minimum');
		await expect(page.getByTestId('public-beta-banner')).toContainText(/public beta/i);
		await expect(pricingMain).toContainText(marketingSnapshot.storage_rate_per_mb_month);
		await expect(pricingMain).toContainText(marketingSnapshot.cold_storage_rate_per_gb_month);
		await expect(pricingMain).toContainText(
			`${sharedPlanMinimumMonthlyLabel(marketingSnapshot.shared_minimum_spend_cents)}/month minimum`
		);

		// URL-obscurity beta gate: pricing CTA + nav Sign Up removed.
		// See docs/decisions/2026_05_23_beta_signup_gate.md.
		await expect(pricingMain.getByRole('link', { name: MARKETING_PRICING.cta_label })).toHaveCount(
			0
		);
		await expect(
			page.getByRole('navigation').getByRole('link', { name: 'Log in' })
		).toHaveAttribute('href', '/login');
		await expect(page.getByRole('navigation').getByRole('link', { name: 'Sign Up' })).toHaveCount(
			0
		);

		const regionTable = pricingMain.getByRole('table', { name: 'Region multipliers' });
		const regionRows = regionTable.getByRole('row');
		await expect(regionRows).toHaveCount(marketingSnapshot.region_pricing.length + 1);
		for (let rowIndex = 0; rowIndex < marketingSnapshot.region_pricing.length; rowIndex += 1) {
			const expectedRegion = marketingSnapshot.region_pricing[rowIndex];
			const renderedRow = regionRows.nth(rowIndex + 1);
			await expect(renderedRow.getByRole('rowheader')).toHaveText(expectedRegion.display_name);
			await expect(renderedRow.getByRole('cell')).toHaveText(expectedRegion.multiplier);
		}

		await expect(pricingMain).not.toContainText('What you get');
		await expect(pricingMain).not.toContainText('Quick facts');
		await expect(pricingMain).not.toContainText('Support reference');
		await expect(pricingMain).not.toContainText('Go home');
		await expect(pricingMain).not.toContainText('The page you requested is not available.');
		await expect(pricingMain).not.toContainText('Not found');
		await expect(page.getByTestId('landing-pricing-calculator')).toHaveCount(0);
		await expect(
			page.getByRole('contentinfo').getByRole('link', { name: 'Terms' })
		).toHaveAttribute(
			'href',
			'/terms'
		);
		await expect(
			page.getByRole('contentinfo').getByRole('link', { name: 'Privacy' })
		).toHaveAttribute(
			'href',
			'/privacy'
		);
		await expect(page.getByRole('contentinfo').getByRole('link', { name: 'DPA' })).toHaveAttribute(
			'href',
			'/dpa'
		);
		await expect(page.getByRole('contentinfo').getByRole('link', { name: 'Status' })).toHaveAttribute(
			'href',
			'/status'
		);
	});

	test('pricing header Log in link navigates to /login', async ({ page }) => {
		await page.goto('/pricing');
		await expect(page.getByTestId('pricing-page-main')).toBeVisible();

		const loginLink = page.getByRole('navigation').getByRole('link', { name: 'Log in' });
		await expect(loginLink).toHaveAttribute('href', '/login');
		await loginLink.click();

		await expect(page).toHaveURL(/\/login/);
		await expect(page.getByRole('heading', { name: 'Log in to Flapjack Cloud' })).toBeVisible();
	});
});

test.describe('Public beta and legal pages', () => {
	test('beta page explains launch scope, support target, feedback, and GA timing', async ({
		page
	}) => {
		await page.goto('/beta');

		await expect(page.getByRole('heading', { name: 'Public Beta' })).toBeVisible();
		await expect(page.getByRole('main')).toContainText('48 business hours');
		await expect(page.getByRole('main')).toContainText('General availability');
		await expect(page.getByRole('link', { name: /email support/i })).toHaveAttribute(
			'href',
			/mailto:support@flapjack\.foo/
		);
		// URL-obscurity beta gate: "Start beta signup" CTAs removed from /beta.
		// See docs/decisions/2026_05_23_beta_signup_gate.md.
		await expect(
			page.getByRole('main').getByRole('link', { name: 'Start beta signup' })
		).toHaveCount(0);
		await expect(page.getByRole('link', { name: 'Terms' })).toHaveAttribute('href', '/terms');
		await expect(page.getByRole('link', { name: 'Privacy' })).toHaveAttribute('href', '/privacy');
		await expect(page.getByRole('link', { name: 'DPA' })).toHaveAttribute('href', '/dpa');
	});

	test('legal routes expose the finalized shared contract for public users', async ({ page }) => {
		const legalPages = [
			{ path: '/terms', heading: 'Terms of Service' },
			{ path: '/privacy', heading: 'Privacy Policy' },
			{ path: '/dpa', heading: 'Data Processing Addendum' }
		];

		for (const legalPage of legalPages) {
			await page.goto(legalPage.path);
			await expect(page).toHaveURL(new RegExp(`${legalPage.path}$`));
			const pageHeading = page.getByRole('heading', {
				name: legalPage.heading,
				level: 1,
				exact: true
			});
			await expect(pageHeading).toHaveCount(1);
			await expect(pageHeading).toBeVisible();
			await assertSharedLegalPageContract(page);
			await expect(page.getByTestId('public-beta-banner')).toContainText(/public beta/i);
			await expect(page.getByRole('main')).not.toContainText('(Draft)');
			await expect(page.getByRole('main')).not.toContainText('[REVIEW:');
			await expect(page.getByRole('main')).not.toContainText('TBD');
		}
	});
});

test.describe('Public error boundary', () => {
	test('unmapped public route renders recovery copy, support reference, and support contact link', async ({
		page
	}) => {
		await page.goto(`/missing-public-route-${Date.now()}`);

		await expect(page.getByRole('heading', { name: 'Page not found' })).toBeVisible();
		await expect(page.getByRole('main')).toContainText(
			/The page you requested is not available\.|Not found/i
		);
		const primaryCta = page.getByRole('link', { name: 'Go home' });
		await expect(primaryCta).toBeVisible();
		await expect(primaryCta).toHaveAttribute('href', '/');

		const supportReferenceLabel = page.getByRole('main').getByText('Support reference');
		await expect(supportReferenceLabel).toHaveCount(1);
		await expect(supportReferenceLabel).toBeVisible();

		const supportReferenceToken = page.getByRole('main').getByText(/^web-[a-f0-9]{12}$/);
		await expect(supportReferenceToken).toHaveCount(1);
		await expect(supportReferenceToken).toBeVisible();

		await expect(page.getByRole('link', { name: 'support@flapjack.foo' })).toHaveAttribute(
			'href',
			/mailto:support@flapjack\.foo\?subject=/
		);
	});
});

test.describe('Status page', () => {
	test('renders status, support, and beta-scope communication links', async ({ page }) => {
		await page.goto('/status');

		await expect(page.getByRole('heading', { name: 'Service Status' })).toBeVisible();
		await expect(page.getByTestId('status-badge')).toContainText('All Systems Operational');
		await expect(page.getByRole('main')).toContainText(
			'Flapjack Cloud operations owns incident updates'
		);
		await expect(page.getByRole('link', { name: /beta scope/i })).toHaveAttribute('href', '/beta');
		await expect(page.getByRole('link', { name: /email support/i })).toHaveAttribute(
			'href',
			/mailto:support@flapjack\.foo/
		);
		await expect(page.getByRole('main')).not.toContainText('incident history');
	});
});
