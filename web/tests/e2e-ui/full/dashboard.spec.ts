/**
 * Full — Dashboard
 *
 * Verifies that the main dashboard page renders all sections correctly
 * for an authenticated customer, including conditional billing estimates.
 */

import type { BrowserContext, Locator, Page } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';
import { formatPeriod, formatCents, SUPPORT_EMAIL } from '../../../src/lib/format';
import { AUTH_COOKIE } from '../../../src/lib/server/auth-session-contracts';
import { CANONICAL_PUBLIC_API_DOCS_URL } from '../../../src/lib/public_api';

const BASE_URL = process.env.BASE_URL ?? 'http://localhost:5173';

async function isDrawerOpen(drawer: Locator): Promise<boolean> {
	return (await drawer.getAttribute('data-nav-open')) === 'true';
}

async function getVisibleDashboardNavRegion(page: Page) {
	const desktopNav = page.getByTestId('dashboard-nav-desktop');
	if (await desktopNav.isVisible()) {
		return desktopNav;
	}

	const mobileNav = page.getByTestId('dashboard-nav-mobile-drawer');
	await expect(mobileNav).toBeVisible();
	if (await isDrawerOpen(mobileNav)) {
		return mobileNav;
	}

	const mobileNavTrigger = page.getByTestId('dashboard-mobile-nav-trigger');
	await expect(mobileNavTrigger).toBeVisible();
	await mobileNavTrigger.click();
	await expect(mobileNav).toHaveAttribute('data-nav-open', 'true');
	return mobileNav;
}

async function expectSidebarNavigation(
	page: Page,
	options: {
		linkName: string;
		heading: string;
		url: RegExp;
		exact?: boolean;
		href: string;
	}
): Promise<void> {
	await page.goto('/dashboard');

	const navigationRegion = await getVisibleDashboardNavRegion(page);
	const link = navigationRegion.getByRole('link', {
		name: options.linkName,
		...(options.exact ? { exact: true } : {})
	});

	await expect(link).toHaveAttribute('href', options.href);
	await Promise.all([page.waitForURL(options.url), link.click()]);
	await expect(page.getByRole('heading', { name: options.heading })).toBeVisible();
}

async function setAuthCookie(context: BrowserContext, token: string): Promise<void> {
	await context.addCookies([
		{
			name: AUTH_COOKIE,
			value: token,
			url: BASE_URL,
			httpOnly: true,
			sameSite: 'Lax'
		}
	]);
}

test.describe('Dashboard page', () => {
	test('load-and-verify: renders core sections with correct headings', async ({ page }) => {
		// Act: navigate to the dashboard
		await page.goto('/dashboard');

		// Assert on page-specific content (not nav text)
		await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible();

		// Indexes card is always present
		await expect(page.getByTestId('indexes-card')).toBeVisible();
		// This heading is inside the card, not the sidebar — distinct enough
		await expect(
			page.getByTestId('indexes-card').getByRole('heading', { name: 'Indexes' })
		).toBeVisible();
		await expect(page.getByTestId('verification-banner')).toHaveCount(0);
	});

	// smoke: intentional shell-only checks — verify sidebar navigation routing,
	// not destination page content. Each test confirms link exists, click lands
	// on the correct URL, and the page-level heading renders.

	test('sidebar link to Indexes targets the indexes page', async ({ page }) => {
		await page.goto('/dashboard');

		const navRegion = await getVisibleDashboardNavRegion(page);
		await expect(navRegion.getByRole('link', { name: 'Indexes', exact: true })).toHaveAttribute(
			'href',
			'/dashboard/indexes'
		);
	});

	test('desktop shell shows nav and help links without opening a drawer', async ({ page }) => {
		await page.setViewportSize({ width: 1280, height: 900 });
		await page.goto('/dashboard');

		const desktopNav = page.getByTestId('dashboard-nav-desktop');
		await expect(desktopNav).toBeVisible();
		await expect(desktopNav.getByRole('link', { name: 'Indexes', exact: true })).toBeVisible();
		await expect(desktopNav.getByRole('link', { name: 'Support', exact: true })).toHaveAttribute(
			'href',
			`mailto:${SUPPORT_EMAIL}`
		);
		await expect(desktopNav.getByRole('link', { name: 'API Docs', exact: true })).toHaveAttribute(
			'href',
			CANONICAL_PUBLIC_API_DOCS_URL
		);
		await expect(page.getByTestId('dashboard-mobile-nav-trigger')).toBeHidden();
	});

	test('mobile shell keeps drawer closed until trigger click and supports dismiss', async ({
		page
	}) => {
		await page.setViewportSize({ width: 390, height: 844 });
		await page.goto('/dashboard');

		const drawer = page.getByTestId('dashboard-nav-mobile-drawer');
		await expect(drawer).toHaveAttribute('data-nav-open', 'false');
		await expect(drawer.getByRole('link', { name: 'Billing', exact: true })).toHaveCount(0);
		await expect(drawer.getByRole('link', { name: 'Support', exact: true })).toHaveCount(0);
		await expect(drawer.getByRole('link', { name: 'API Docs', exact: true })).toHaveCount(0);

		const trigger = page.getByTestId('dashboard-mobile-nav-trigger');
		await expect(trigger).toBeVisible();
		await trigger.click();

		await expect(drawer).toHaveAttribute('data-nav-open', 'true');
		await expect(drawer.getByRole('link', { name: 'Support', exact: true })).toHaveAttribute(
			'href',
			`mailto:${SUPPORT_EMAIL}`
		);
		await expect(drawer.getByRole('link', { name: 'API Docs', exact: true })).toHaveAttribute(
			'href',
			CANONICAL_PUBLIC_API_DOCS_URL
		);

		await page.getByTestId('dashboard-mobile-nav-dismiss').click();
		await expect(drawer).toHaveAttribute('data-nav-open', 'false');
		await expect(drawer.getByRole('link', { name: 'Billing', exact: true })).toHaveCount(0);
		await expect(drawer.getByRole('link', { name: 'Support', exact: true })).toHaveCount(0);
		await expect(drawer.getByRole('link', { name: 'API Docs', exact: true })).toHaveCount(0);
	});

	test('sidebar link to API Keys reaches the API keys page', async ({ page }) => {
		await expectSidebarNavigation(page, {
			linkName: 'API Keys',
			heading: 'API Keys',
			url: /\/dashboard\/api-keys/,
			href: '/dashboard/api-keys'
		});
	});

	test('sidebar link to Billing reaches the billing page', async ({ page }) => {
		await expectSidebarNavigation(page, {
			linkName: 'Billing',
			heading: 'Billing',
			url: /\/dashboard\/billing/,
			exact: true,
			href: '/dashboard/billing'
		});
	});

	test('mobile sidebar link to Billing reaches the billing page', async ({ page }) => {
		await page.setViewportSize({ width: 390, height: 844 });
		await expectSidebarNavigation(page, {
			linkName: 'Billing',
			heading: 'Billing',
			url: /\/dashboard\/billing/,
			exact: true,
			href: '/dashboard/billing'
		});
	});

	test('sidebar link to Settings reaches the settings page', async ({ page }) => {
		await expectSidebarNavigation(page, {
			linkName: 'Settings',
			heading: 'Settings',
			url: /\/dashboard\/settings/,
			href: '/dashboard/settings'
		});
	});

	test('logs route shows save-settings entry from shared dashboard log path', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		const indexName = `dash-logs-${Date.now()}`;
		await seedIndex(indexName, testRegion);

		await page.goto(`/dashboard/indexes/${encodeURIComponent(indexName)}`);
		await expect(page.getByRole('heading', { name: indexName })).toBeVisible();

		await page.getByRole('tab', { name: 'Settings' }).click();
		const settingsSection = page.getByTestId('settings-section');
		await expect(settingsSection).toBeVisible();
		await settingsSection.getByRole('button', { name: 'Save Settings' }).click();
		await expect(settingsSection).toContainText(/Settings saved\.|Failed to save settings/);

		const logsLink = page.getByRole('navigation').getByRole('link', { name: 'Logs', exact: true });
		await expect(logsLink).toHaveAttribute('href', '/dashboard/logs');
		await logsLink.click();

		await expect(page).toHaveURL(/\/dashboard\/logs/);
		await expect(page.getByRole('heading', { name: 'API Logs' })).toBeVisible();

		const logPanel = page.getByTestId('search-log-panel');
		const firstDataRow = logPanel.getByTestId('api-log-row-0');
		await expect(firstDataRow).toContainText('?/saveSettings');
		await expect(firstDataRow).toContainText('POST');

		await firstDataRow.click();
		await expect(logPanel.getByText('"method": "POST"')).toBeVisible();
		await expect(logPanel.getByText('"url": "?/saveSettings"')).toBeVisible();

		await logPanel.getByRole('button', { name: 'Clear' }).click();
		await expect(logPanel.getByText('No API calls recorded')).toBeVisible();
		await expect(logPanel.getByText('Request')).toHaveCount(0);
	});

	test('dashboard shows "Manage indexes" link when indexes exist', async ({ page, seedIndex }) => {
		const name = `dash-idx-${Date.now()}`;
		await seedIndex(name);

		await page.goto('/dashboard');

		await expect(page.getByRole('link', { name: 'Manage indexes' })).toBeVisible();
	});

	test('estimated bill widget renders exact backend month and total', async ({
		page,
		getEstimatedBill
	}) => {
		const estimate = await getEstimatedBill();

		await page.goto('/dashboard');
		const widget = page.getByTestId('estimated-bill');

		if (!estimate) {
			// No estimate exists yet — widget must be hidden
			await expect(widget).toHaveCount(0);
			return;
		}

		// Rate card exists — widget visible with correct month and total
		await expect(widget).toBeVisible();
		await expect(widget.getByRole('heading')).toHaveText(
			`Estimated Bill for ${formatPeriod(estimate.month + '-01')}`
		);
		await expect(widget.getByTestId('estimated-bill-total')).toHaveText(
			formatCents(estimate.total_cents)
		);
	});

	test('estimated bill widget expands breakdown when backend returns line items', async ({
		page,
		getEstimatedBill
	}) => {
		const estimate = await getEstimatedBill();

		await page.goto('/dashboard');
		const widget = page.getByTestId('estimated-bill');

		if (!estimate) {
			// No estimate exists yet — widget must be hidden
			await expect(widget).toHaveCount(0);
			return;
		}

		// Widget is visible with an estimate
		await expect(widget).toBeVisible();

		if (estimate.line_items.length === 0) {
			// Zero usage — widget renders summary but no breakdown control
			await expect(widget.getByText('View breakdown')).toHaveCount(0);
			return;
		}

		// Line items present — breakdown toggle and table must work
		const breakdownToggle = widget.getByText('View breakdown');
		await expect(breakdownToggle).toBeVisible();
		await breakdownToggle.click();
		await expect(widget.getByRole('table')).toBeVisible();
		await expect(widget.getByRole('columnheader', { name: 'Description' })).toBeVisible();
		await expect(widget.getByRole('columnheader', { name: 'Amount' })).toBeVisible();
		const firstLineItem = estimate.line_items[0]!;
		await expect(widget.getByRole('cell', { name: firstLineItem.description })).toBeVisible();
		await expect(
			widget
				.getByRole('row')
				.nth(1)
				.getByRole('cell', { name: formatCents(firstLineItem.amount_cents) })
		).toBeVisible();
	});
});

test.describe('Dashboard verification banner', () => {
	test.use({ storageState: { cookies: [], origins: [] } });

	type CreateUserFixture = (
		email: string,
		password: string,
		name: string
	) => Promise<{ email: string }>;
	type LoginAsFixture = (email: string, password: string) => Promise<string>;

	async function authenticateUnverifiedUser(
		page: Page,
		createUser: CreateUserFixture,
		loginAs: LoginAsFixture
	): Promise<void> {
		const password = 'TestPassword123!';
		const seed = Date.now();
		const email = `dashboard-unverified-${seed}@e2e.griddle.test`;
		const created = await createUser(email, password, `Dashboard Unverified ${seed}`);
		const token = await loginAs(created.email, password);
		await setAuthCookie(page.context(), token);
	}

	test('unverified user can resend verification in shell and keeps success message across dashboard navigation', async ({
		page,
		createUser,
		loginAs
	}) => {
		await authenticateUnverifiedUser(page, createUser, loginAs);

		await page.goto('/dashboard');
		const banner = page.getByTestId('verification-banner');
		const resendButton = page.getByTestId('verification-resend-button');
		const resultMessage = page.getByTestId('verification-resend-message');

		await expect(banner).toBeVisible();
		await expect(resendButton).toBeVisible();
		await resendButton.click();
		await expect(page).toHaveURL(/\/dashboard$/);
		await expect(resultMessage).toBeVisible({ timeout: 10_000 });
		await expect(resultMessage).toContainText(/verification email sent/i);
		await Promise.all([
			page.waitForURL(/\/dashboard\/settings/),
			page.getByRole('navigation').getByRole('link', { name: 'Settings' }).click()
		]);
		await expect(resultMessage).toBeVisible();
		await expect(resultMessage).toContainText(/verification email sent/i);
	});

	test('unverified banner renders deterministic 400 resend error without redirecting to settings', async ({
		page,
		createUser,
		loginAs
	}) => {
		await authenticateUnverifiedUser(page, createUser, loginAs);
		await page.route('**/dashboard/resend-verification', async (route) => {
			await route.fulfill({
				status: 400,
				contentType: 'application/json',
				body: JSON.stringify({ error: 'email_already_verified', retryAfterSeconds: null })
			});
		});

		await page.goto('/dashboard');
		const banner = page.getByTestId('verification-banner');
		const resendButton = page.getByTestId('verification-resend-button');
		const resultMessage = page.getByTestId('verification-resend-message');

		await expect(banner).toBeVisible();
		await resendButton.click();
		await expect(resultMessage).toContainText('email_already_verified');
		await expect(page).toHaveURL(/\/dashboard$/);
		await expect(page.getByTestId('verification-cooldown-copy')).toHaveCount(0);
	});

	test('unverified banner renders deterministic 429 cooldown copy from resend response', async ({
		page,
		createUser,
		loginAs
	}) => {
		await authenticateUnverifiedUser(page, createUser, loginAs);
		await page.route('**/dashboard/resend-verification', async (route) => {
			await route.fulfill({
				status: 429,
				headers: {
					'Content-Type': 'application/json',
					'Retry-After': '90'
				},
				body: JSON.stringify({ error: 'resend_rate_limited', retryAfterSeconds: 90 })
			});
		});

		await page.goto('/dashboard');
		const banner = page.getByTestId('verification-banner');
		const resendButton = page.getByTestId('verification-resend-button');
		const resultMessage = page.getByTestId('verification-resend-message');

		await expect(banner).toBeVisible();
		await resendButton.click();
		await expect(resultMessage).toContainText('resend_rate_limited');
		await expect(page.getByTestId('verification-cooldown-copy')).toContainText('90');
		await expect(page).toHaveURL(/\/dashboard$/);
	});
});

test.describe('Plan-aware dashboard features', () => {
	test('plan badge displays the user plan type', async ({ page }) => {
		await page.goto('/dashboard');

		const badge = page.getByTestId('plan-badge');
		await expect(badge).toBeVisible();
		// E2E seed user is on shared plan; badge must show the plan name
		await expect(badge).toHaveText('Shared Plan');
	});

	test('shared-plan billing prompt navigates to billing setup', async ({ page }) => {
		await page.goto('/dashboard');

		// The billing prompt appears for shared-plan users without a payment method
		const billingPrompt = page.getByTestId('billing-prompt');
		await expect(billingPrompt).toBeVisible();
		await expect(billingPrompt.getByText('Add a payment method to continue setup')).toBeVisible();

		// Navigate via the "Add payment method" link
		await billingPrompt.getByRole('link', { name: 'Add payment method' }).click();
		await expect(page).toHaveURL(/\/dashboard\/billing\/setup/);
		await expect(page.getByRole('heading', { name: 'Add Payment Method' })).toBeVisible();
	});

	test('layout billing CTA navigates to billing page', async ({ page }) => {
		await page.goto('/dashboard');

		const cta = page.getByTestId('billing-cta');
		await expect(cta).toBeVisible();
		await expect(
			cta.getByText('Your shared plan requires billing setup to continue.')
		).toBeVisible();

		// Navigate via the "Set up billing" link in the layout CTA
		await cta.getByRole('link', { name: 'Set up billing' }).click();
		await expect(page).toHaveURL(/\/dashboard\/billing/);
		await expect(page.getByRole('heading', { name: 'Billing' })).toBeVisible();
	});

	test('free-tier progress is hidden for shared-plan users', async ({ page }) => {
		await page.goto('/dashboard');

		// Confirm shared plan
		await expect(page.getByTestId('plan-badge')).toHaveText('Shared Plan');
		// Free-tier progress section must not appear for shared-plan users
		await expect(page.getByTestId('free-tier-progress')).toBeHidden();
	});

	test('free-plan dashboard shows free-tier usage without shared-plan billing prompts', async ({
		page,
		setBillingPlan
	}) => {
		await setBillingPlan('free');
		await page.goto('/dashboard');

		await expect(page.getByTestId('plan-badge')).toHaveText('Free Plan');

		// Assert free-tier-progress renders metric labels and structured content
		const progress = page.getByTestId('free-tier-progress');
		await expect(progress).toBeVisible();
		await expect(progress.getByText('Free Plan Usage')).toBeVisible();
		await expect(progress.getByText('Searches')).toBeVisible();
		await expect(progress.getByText('Records')).toBeVisible();
		await expect(progress.getByText('Storage (GB)')).toBeVisible();
		await expect(progress.getByText('Indexes')).toBeVisible();
		// All four cards should render a concrete "used / limit" value row, not just one.
		await expect(progress.getByText(/\d[\d,.]* \/ \d[\d,.]*/)).toHaveCount(4);

		await expect(page.getByTestId('billing-prompt')).toHaveCount(0);
		await expect(page.getByTestId('billing-cta')).toHaveCount(0);
	});
});

test.describe('Dashboard error boundary', () => {
	test('unmapped dashboard route renders public recovery copy with one support reference', async ({
		page
	}) => {
		await page.goto(`/dashboard/missing-route-${Date.now()}`);

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
