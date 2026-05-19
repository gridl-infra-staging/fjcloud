import { test, expect } from '../../fixtures/fixtures';
import type { Page } from '@playwright/test';
import {
	isRemoteTargetMode,
	setAuthCookieForToken
} from '../../fixtures/fresh_signup_remote_bootstrap';

// Dedicated unauthenticated lane: this flow must not rely on setup:user storage.
test.use({ storageState: { cookies: [], origins: [] } });

type DashboardRouteExpectation = {
	label: string;
	path: string;
	heading: string;
};

const DASHBOARD_ROUTE_EXPECTATIONS: DashboardRouteExpectation[] = [
	{ label: 'Dashboard', path: '/dashboard', heading: 'Dashboard' },
	{ label: 'Indexes', path: '/dashboard/indexes', heading: 'Indexes' },
	{ label: 'Billing', path: '/dashboard/billing', heading: 'Billing' },
	{ label: 'API Keys', path: '/dashboard/api-keys', heading: 'API Keys' },
	{ label: 'Logs', path: '/dashboard/logs', heading: 'API Logs' },
	{ label: 'Migrate', path: '/dashboard/migrate', heading: 'Migrate from Algolia' },
	{ label: 'Account', path: '/dashboard/account', heading: 'Account' }
];
const TRANSIENT_RATE_LIMIT_PATTERN = /too many requests/i;

async function loginWithFreshSignupCredentials(
	page: import('@playwright/test').Page,
	email: string,
	password: string,
	loginAs?: (email: string, password: string) => Promise<string>
): Promise<void> {
	await expect(async () => {
		await page.goto('/login');
		await page.getByLabel('Email').fill(email);
		await page.getByLabel('Password').fill(password);
		await page.getByRole('button', { name: 'Log In' }).click();

		try {
			await expect(page).toHaveURL(/\/dashboard/, { timeout: 20_000 });
			return;
		} catch (error) {
			const loginAlert = page.getByRole('alert');
			const alertText = (await loginAlert.textContent().catch(() => null))?.trim() ?? '';
			if (TRANSIENT_RATE_LIMIT_PATTERN.test(alertText)) {
				throw new Error('Fresh-signup login was transiently rate-limited; retrying');
			}
			if (!isRemoteTargetMode() || !loginAs) {
				throw error;
			}

			const token = await loginAs(email, password);
			await setAuthCookieForToken(page, token);
			await page.goto('/dashboard');
			await expect(page).toHaveURL(/\/dashboard/, { timeout: 20_000 });
		}
	}).toPass({
		intervals: [1_000, 2_000, 3_000, 4_000, 5_000],
		timeout: 60_000
	});
}

async function assertDashboardRouteWalk(page: import('@playwright/test').Page): Promise<void> {
	for (const route of DASHBOARD_ROUTE_EXPECTATIONS) {
		await page.getByRole('link', { name: route.label }).click();
		await expect(
			page.getByRole('heading', {
				name: route.heading,
				exact: true
			})
		).toBeVisible({ timeout: 15_000 });
		await expect(page).toHaveURL(new RegExp(`${route.path}(?:$|\\?)`));
		await expect(page.getByTestId('dashboard-beta-support-badge')).toBeVisible();
	}
}

function escapeRegex(value: string): string {
	return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

async function expectInvoiceHeaderStatusBadge(page: Page, statusLabel: string): Promise<void> {
	const exactStatusText = new RegExp(`^${escapeRegex(statusLabel)}$`);
	const visibleStatusLabels = page.getByText(exactStatusText).filter({ visible: true });
	await expect(visibleStatusLabels).toHaveCount(2);
	await expect(visibleStatusLabels.first()).toBeVisible();
}

async function expectInvoiceTimelineLabelHasNonEmptyValue(
	page: Page,
	label: string
): Promise<void> {
	const timelineLabelWithValue = page.getByText(new RegExp(`^\\s*${escapeRegex(label)}\\s+\\S.+$`));
	await expect(timelineLabelWithValue).toHaveCount(1);
	await expect(timelineLabelWithValue).toBeVisible();
}

async function expectInvoiceTimelineLabelsWithValues(page: Page): Promise<void> {
	for (const label of ['Created', 'Finalized', 'Paid']) {
		await expectInvoiceTimelineLabelHasNonEmptyValue(page, label);
	}
}

test.describe('Fresh signup to paid invoice', () => {
	// Signup + verification + billing can take multiple async backend cycles.
	test.describe.configure({ retries: 0 });

	test('signs up, verifies email, reaches paid invoice evidence', async ({
		page,
		loginAs,
		createFreshSignupIdentity,
		arrangeFreshSignupToDashboard,
		completeFreshSignupEmailVerification,
		arrangePaidInvoiceForFreshSignup
	}) => {
		test.setTimeout(300_000);

		const signup = createFreshSignupIdentity();
		const arrangeResult = await arrangeFreshSignupToDashboard(page, signup);
		if (arrangeResult.prerequisiteFailureMessage) {
			test.skip(
				true,
				`fresh-signup prerequisite unavailable in local env: ${arrangeResult.prerequisiteFailureMessage}`
			);
			return;
		}

		await expect(page).toHaveURL(/\/dashboard/, { timeout: 20_000 });
		await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible();

		const { verificationToken } = await completeFreshSignupEmailVerification(page, signup.email);
		await page.goto(`/verify-email/${verificationToken}`);
		await expect(page.getByRole('heading', { name: 'Verification Failed' })).toBeVisible({
			timeout: 20_000
		});
		await expect(page.getByText(/invalid or expired verification token/i)).toBeVisible();

		await loginWithFreshSignupCredentials(page, signup.email, signup.password, loginAs);
		await page.goto('/dashboard');
		await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible();
		await assertDashboardRouteWalk(page);

		const paidInvoiceEvidence = await arrangePaidInvoiceForFreshSignup(
			signup.email,
			signup.password
		);

		await page.goto('/dashboard/billing/invoices');
		await expect(page.getByRole('heading', { name: 'Invoices' })).toBeVisible();
		const invoiceRow = page.getByTestId(`invoice-row-${paidInvoiceEvidence.invoiceId}`);
		await expect(invoiceRow).toBeVisible({ timeout: 30_000 });
		await expect(invoiceRow.getByRole('link', { name: 'View' })).toBeVisible();
		await expect(invoiceRow.getByText('Paid')).toBeVisible();
		const invoiceLink = page.getByTestId(`invoice-row-link-${paidInvoiceEvidence.invoiceId}`);
		await expect(invoiceLink).toBeVisible({ timeout: 30_000 });
		await invoiceLink.click();
		await expect(page).toHaveURL(
			new RegExp(`/dashboard/billing/invoices/${paidInvoiceEvidence.invoiceId}$`)
		);
		await expect(page.getByRole('heading', { name: 'Line Items' })).toBeVisible();
		await expectInvoiceHeaderStatusBadge(page, 'Paid');
		await expectInvoiceTimelineLabelsWithValues(page);
	});
});
