/**
 * Full — Dashboard
 *
 * Verifies that the main dashboard page renders all sections correctly
 * for an authenticated customer, including conditional billing estimates.
 */

import type { Page } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';
import { formatPeriod, formatCents } from '../../../src/lib/format';

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

	const link = page.getByRole('navigation').getByRole('link', {
		name: options.linkName,
		...(options.exact ? { exact: true } : {}),
	});

	await expect(link).toHaveAttribute('href', options.href);
	await Promise.all([page.waitForURL(options.url), link.click()]);
	await expect(page.getByRole('heading', { name: options.heading })).toBeVisible();
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
	});

	// smoke: intentional shell-only checks — verify sidebar navigation routing,
	// not destination page content. Each test confirms link exists, click lands
	// on the correct URL, and the page-level heading renders.

	test('sidebar link to Indexes targets the indexes page', async ({ page }) => {
		await page.goto('/dashboard');

		await expect(
			page.getByRole('navigation').getByRole('link', { name: 'Indexes', exact: true })
		).toHaveAttribute('href', '/dashboard/indexes');
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
			heading: 'Payment Methods',
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
			href: '/dashboard/settings',
		});
	});

	test('sidebar link to Database reaches persisted instance details', async ({
		page,
		arrangeDatabaseRouteState
	}) => {
		const arrangedState = await arrangeDatabaseRouteState();

		await page.goto('/dashboard');
		const databaseLink = page.getByRole('navigation').getByRole('link', {
			name: 'Database',
			exact: true
		});
		await expect(databaseLink).toHaveAttribute('href', '/dashboard/database');

		await databaseLink.click();
		await expect(page).toHaveURL(/\/dashboard\/database/);
		await expect(page.getByRole('heading', { name: 'Database' })).toBeVisible();

		if (arrangedState.branch !== 'persisted') {
			throw new Error(`Unexpected database arrange branch: ${arrangedState.branch}`);
		}
		await expect(page.getByText('AllYourBase Instance')).toBeVisible();
		await expect(page.getByText(arrangedState.instance.id)).toBeVisible();
		await expect(page.getByText(arrangedState.instance.statusLabel)).toBeVisible();
		await expect(page.getByText('Database URL')).toBeVisible();
		await expect(page.getByText(arrangedState.instance.aybUrl)).toBeVisible();
		await expect(page.getByText('Slug')).toBeVisible();
		await expect(page.getByText(arrangedState.instance.aybSlug)).toBeVisible();
		await expect(page.getByText('Cluster ID')).toBeVisible();
		await expect(page.getByText(arrangedState.instance.aybClusterId)).toBeVisible();
		await expect(page.getByText('Plan')).toBeVisible();
		await expect(page.getByText(arrangedState.instance.plan)).toBeVisible();
		await expect(page.getByTestId('create-instance-form')).toHaveCount(0);
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
		await expect(settingsSection.getByText('Settings saved.')).toBeVisible();

		const logsLink = page.getByRole('navigation').getByRole('link', { name: 'Logs', exact: true });
		await expect(logsLink).toHaveAttribute('href', '/dashboard/logs');
		await logsLink.click();

		await expect(page).toHaveURL(/\/dashboard\/logs/);
		await expect(page.getByRole('heading', { name: 'API Logs' })).toBeVisible();

		const logPanel = page.getByTestId('search-log-panel');
		const firstDataRow = logPanel.getByTestId('api-log-row-0');
		await expect(firstDataRow).toContainText('?/saveSettings');
		await expect(firstDataRow).toContainText('POST');
		await expect(firstDataRow).toContainText('200');

		await firstDataRow.click();
		await expect(logPanel.getByText('"method": "POST"')).toBeVisible();
		await expect(logPanel.getByText('"url": "?/saveSettings"')).toBeVisible();
		await expect(logPanel.getByText('"status": 200')).toBeVisible();
		await expect(logPanel.getByText('"settingsSaved": true')).toBeVisible();

		await logPanel.getByRole('button', { name: 'Clear' }).click();
		await expect(logPanel.getByText('No API calls recorded')).toBeVisible();
		await expect(logPanel.getByText('Request')).toHaveCount(0);
	});

	test('dashboard shows "Manage indexes" link when indexes exist', async ({
		page,
		seedIndex,
	}) => {
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
			widget.getByRole('cell', { name: formatCents(firstLineItem.amount_cents) })
		).toBeVisible();
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
		await expect(
			billingPrompt.getByText('Add a payment method to continue setup')
		).toBeVisible();

		// Navigate via the "Add payment method" link
		await billingPrompt.getByRole('link', { name: 'Add payment method' }).click();
		await expect(page).toHaveURL(/\/dashboard\/billing\/setup/);
		await expect(
			page.getByRole('heading', { name: 'Add Payment Method' })
		).toBeVisible();
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
		await expect(
			page.getByRole('heading', { name: 'Payment Methods' })
		).toBeVisible();
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
		setBillingPlan,
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
	test('unmapped dashboard route renders dashboard recovery copy with one support reference', async ({
		page
	}) => {
		await page.goto(`/dashboard/missing-route-${Date.now()}`);

		await expect(page.getByRole('heading', { name: 'Page not found' })).toBeVisible();
		await expect(page.getByRole('main')).toContainText(
			/The page you requested is not available\.|Not found/i
		);
		const primaryCta = page.getByRole('link', { name: 'Go to dashboard' });
		await expect(primaryCta).toBeVisible();
		await expect(primaryCta).toHaveAttribute('href', '/dashboard');

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
