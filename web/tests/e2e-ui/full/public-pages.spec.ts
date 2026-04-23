/**
 * Full — Public Pages
 *
 * Verifies pages that are accessible without authentication:
 *   - Landing page (/)
 *   - Status page (/status)
 *
 * These tests do not use stored auth state.
 */

import { test, expect } from '@playwright/test';
import { MARKETING_PRICING } from '../../../src/lib/pricing';
import { assertPricingCalculatorOutcome } from '../../fixtures/public-pages';

// Unauthenticated — no stored auth state needed
test.use({ storageState: { cookies: [], origins: [] } });

test.describe('Landing page', () => {
	test('load-and-verify: landing page renders brand plus hero and pricing sections', async ({
		page
	}) => {
		await page.goto('/');

		await expect(page).toHaveTitle(/Flapjack Cloud/);
		await expect(page).not.toHaveTitle(/Griddle/);

		// Brand name in the public header.
		await expect(page.getByRole('link', { name: 'Flapjack Cloud' })).toBeVisible();
		await expect(page.getByRole('heading', { name: 'Flapjack Cloud' })).toBeVisible();
		await expect(page.getByRole('heading', { name: 'What you get' })).toBeVisible();
		await expect(page.getByRole('heading', { name: 'Simple pricing' })).toBeVisible();
		await expect(page.getByRole('main')).not.toContainText('Griddle');

		// Nav auth links are visible
		await expect(page.getByRole('link', { name: 'GitHub repository' })).toHaveAttribute(
			'href',
			'https://github.com/gridlhq/flapjack'
		);
		await expect(page.getByRole('navigation').getByRole('link', { name: 'Log In' })).toBeVisible();
		await expect(page.getByRole('navigation').getByRole('link', { name: 'Sign Up' })).toBeVisible();
		await expect(page.getByRole('link', { name: 'View API Docs' })).toHaveAttribute(
			'href',
			'https://api.flapjack.foo/docs'
		);
		await expect(page.getByTestId('public-beta-banner')).toContainText(/public beta/i);
		await expect(page.getByRole('link', { name: /learn about the beta/i })).toHaveAttribute(
			'href',
			'/beta'
		);
		await expect(
			page.getByRole('contentinfo').getByRole('link', { name: 'Terms' })
		).toHaveAttribute('href', '/terms');
		await expect(
			page.getByRole('contentinfo').getByRole('link', { name: 'Privacy' })
		).toHaveAttribute('href', '/privacy');
		await expect(page.getByRole('contentinfo').getByRole('link', { name: 'DPA' })).toHaveAttribute(
			'href',
			'/dpa'
		);
	});

	test('Log In link reaches the login page', async ({ page }) => {
		await page.goto('/');

		await page.getByRole('navigation').getByRole('link', { name: 'Log In' }).click();

		await expect(page).toHaveURL(/\/login/);
		await expect(page).toHaveTitle(/Flapjack Cloud/);
		await expect(page).not.toHaveTitle(/Griddle/);
		await expect(page.getByRole('heading', { name: 'Log in to Flapjack Cloud' })).toBeVisible();
	});

	test('Sign Up link reaches the signup page', async ({ page }) => {
		await page.goto('/');

		await page.getByRole('navigation').getByRole('link', { name: 'Sign Up' }).click();

		await expect(page).toHaveURL(/\/signup/);
		await expect(page.getByRole('heading', { name: 'Create your account' })).toBeVisible();
	});

	test('landing body shows free-tier promise and body CTA drives signup flow', async ({ page }) => {
		await page.goto('/');

		const freeTierPromiseMatches = page.getByText(MARKETING_PRICING.free_tier_promise);
		expect(await freeTierPromiseMatches.count()).toBeGreaterThanOrEqual(3);

		const bodyCta = page
			.getByRole('main')
			.getByRole('link', { name: MARKETING_PRICING.cta_label })
			.first();
		await expect(bodyCta).toBeVisible();
		await bodyCta.click();

		await expect(page).toHaveURL(/\/signup/);
		await expect(page.getByRole('heading', { name: 'Create your account' })).toBeVisible();
		await expect(page.getByText(MARKETING_PRICING.free_tier_promise)).toBeVisible();
	});

	test('interactive pricing calculator returns Flapjack Cloud and competitor rows', async ({
		page
	}) => {
		await page.goto('/');

		await expect(page.getByRole('heading', { name: 'Simple pricing' })).toBeVisible();
		await expect(page.getByText(MARKETING_PRICING.free_tier_promise).first()).toBeVisible();
		await expect(page.getByTestId('landing-pricing-calculator')).toBeVisible();

		await page.getByLabel('Document count').fill('120000');
		await page.getByLabel('Average document size (bytes)').fill('1500');
		await page.getByLabel('Search requests per month').fill('250000');
		await page.getByLabel('Write operations per month').fill('30000');
		await page.getByLabel('Sort directions').fill('2');
		await page.getByLabel('Index count').fill('1');
		await expect(page.getByLabel('Region')).toHaveCount(0);

		await page.getByRole('button', { name: 'Compare monthly cost' }).click();
		await assertPricingCalculatorOutcome(page);
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
		await expect(
			page.getByRole('main').getByRole('link', { name: 'Start beta signup' })
		).toHaveAttribute('href', /\/signup$/);
		await expect(page.getByRole('link', { name: 'Terms' })).toHaveAttribute('href', '/terms');
		await expect(page.getByRole('link', { name: 'Privacy' })).toHaveAttribute('href', '/privacy');
		await expect(page.getByRole('link', { name: 'DPA' })).toHaveAttribute('href', '/dpa');
	});

	test('legal pages are reachable from public routes', async ({ page }) => {
		await page.goto('/terms');
		await expect(page.getByRole('heading', { name: 'Terms of Service' })).toBeVisible();
		await expect(page.getByRole('main')).toContainText('public beta');

		await page.goto('/privacy');
		await expect(page.getByRole('heading', { name: 'Privacy Policy' })).toBeVisible();
		await expect(page.getByRole('main')).toContainText('Data export');

		await page.goto('/dpa');
		await expect(page.getByRole('heading', { name: 'Data Processing Addendum' })).toBeVisible();
		await expect(page.getByRole('main')).toContainText('Data Processing Addendum');
		await expect(page.getByRole('main')).toContainText('subprocessor questions');
		await expect(page.getByRole('main')).not.toContainText('subprocesser');
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
