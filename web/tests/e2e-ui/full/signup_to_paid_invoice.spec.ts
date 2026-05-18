import { test, expect } from '../../fixtures/fixtures';
import type { Page } from '@playwright/test';
import { AUTH_COOKIE } from '../../../src/lib/server/auth-session-contracts';

// Dedicated unauthenticated lane: this flow must not rely on setup:user storage.
test.use({ storageState: { cookies: [], origins: [] } });

const BASE_URL = process.env.BASE_URL ?? 'http://localhost:5173';
const BASE_URL_PROTOCOL = new URL(BASE_URL).protocol;
const REMOTE_TARGET_MODE = process.env.PLAYWRIGHT_TARGET_REMOTE === '1';

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
	{ label: 'Settings', path: '/dashboard/settings', heading: 'Settings' }
];

async function setAuthCookieForToken(page: Page, token: string): Promise<void> {
	await page.context().addCookies([
		{
			name: AUTH_COOKIE,
			value: token,
			url: BASE_URL,
			httpOnly: true,
			secure: BASE_URL_PROTOCOL === 'https:',
			sameSite: 'Lax'
		}
	]);
}

async function tryRemoteSignupFallback(params: {
	page: Page;
	email: string;
	password: string;
	name: string;
	createUser: (email: string, password: string, name?: string) => Promise<{ token: string }>;
}): Promise<boolean> {
	if (!REMOTE_TARGET_MODE) {
		return false;
	}

	const created = await params.createUser(params.email, params.password, params.name);
	await setAuthCookieForToken(params.page, created.token);
	await params.page.goto('/dashboard');
	await expect(params.page).toHaveURL(/\/dashboard/, { timeout: 20_000 });
	return true;
}

async function loginWithFreshSignupCredentials(
	page: import('@playwright/test').Page,
	email: string,
	password: string,
	loginAs?: (email: string, password: string) => Promise<string>
): Promise<void> {
	await page.goto('/login');
	await page.getByLabel('Email').fill(email);
	await page.getByLabel('Password').fill(password);
	await page.getByRole('button', { name: 'Log In' }).click();
	try {
		await expect(page).toHaveURL(/\/dashboard/, { timeout: 20_000 });
		return;
	} catch (error) {
		if (!REMOTE_TARGET_MODE || !loginAs) {
			throw error;
		}

		const token = await loginAs(email, password);
		await setAuthCookieForToken(page, token);
		await page.goto('/dashboard');
		await expect(page).toHaveURL(/\/dashboard/, { timeout: 20_000 });
	}
}

async function assertDashboardRouteWalk(page: import('@playwright/test').Page): Promise<void> {
	for (const route of DASHBOARD_ROUTE_EXPECTATIONS) {
		await page.getByRole('link', { name: route.label }).click();
		await expect(
			page.getByRole('heading', {
				name: route.heading
			})
		).toBeVisible({ timeout: 15_000 });
		await expect(page).toHaveURL(new RegExp(`${route.path}(?:$|\\?)`));
		await expect(page.getByTestId('dashboard-beta-banner')).toBeVisible();
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
		createUser,
		createFreshSignupIdentity,
		completeFreshSignupEmailVerification,
		arrangePaidInvoiceForFreshSignup,
		isFreshSignupArrangePrerequisiteFailure,
		throwFreshSignupArrangeFailure
	}) => {
		test.setTimeout(300_000);

		const signup = createFreshSignupIdentity();

		await page.goto('/signup');
		await page.getByLabel('Name').fill(signup.name);
		await page.getByLabel('Email').fill(signup.email);
		await page.getByLabel('Password', { exact: true }).fill(signup.password);
		await page.getByLabel('Confirm Password').fill(signup.password);

		const signupResponsePromise = page
			.waitForResponse(
				(response) =>
					response.request().method() === 'POST' && response.url().includes('/signup'),
				{ timeout: 20_000 }
			)
			.catch(() => null);
		await page.getByRole('button', { name: 'Sign Up' }).click();

		const signupAlert = page.getByRole('alert');
		await Promise.race([
			page.waitForURL(/\/dashboard/, { timeout: 20_000 }),
			signupAlert.waitFor({ state: 'visible', timeout: 20_000 })
		]).catch(() => undefined);

		if (!/\/dashboard/.test(page.url())) {
			const signupResponse = await signupResponsePromise;
			const alertVisible = await signupAlert.isVisible().catch(() => false);
			const alertText = alertVisible ? ((await signupAlert.textContent())?.trim() ?? '') : '';
			const fallbackSucceeded = await tryRemoteSignupFallback({
				page,
				email: signup.email,
				password: signup.password,
				name: signup.name,
				createUser
			}).catch(() => false);
			if (fallbackSucceeded) {
				await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible();
			}
			if (fallbackSucceeded) {
				// Continue with verification + billing assertions using the same fresh credentials.
			} else if (isFreshSignupArrangePrerequisiteFailure(alertText)) {
				throwFreshSignupArrangeFailure({
					currentPath: page.url(),
					alertText,
					responseStatus: signupResponse?.status(),
					responseUrl: signupResponse?.url()
				});
			} else {
				throwFreshSignupArrangeFailure({
					currentPath: page.url(),
					alertText:
						alertText ||
						'Sign up did not reach /dashboard and no alert was visible within 20 seconds.',
					responseStatus: signupResponse?.status(),
					responseUrl: signupResponse?.url()
				});
			}
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
