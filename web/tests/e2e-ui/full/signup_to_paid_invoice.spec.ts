import { test, expect } from '../../fixtures/fixtures';
import { AUTH_COOKIE } from '../../../src/lib/server/auth-session-contracts';

// Dedicated unauthenticated lane: this flow must not rely on setup:user storage.
test.use({ storageState: { cookies: [], origins: [] } });

const BASE_URL = process.env.BASE_URL ?? 'http://localhost:5173';

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

async function loginWithFreshSignupCredentials(
	page: import('@playwright/test').Page,
	email: string,
	password: string
): Promise<void> {
	await page.goto('/login');
	await page.getByLabel('Email').fill(email);
	await page.getByLabel('Password').fill(password);
	await page.getByRole('button', { name: 'Log In' }).click();
	await expect(page).toHaveURL(/\/dashboard/, { timeout: 20_000 });
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

function invoiceDetailCard(page: import('@playwright/test').Page) {
	return page.locator('div.rounded-lg.bg-white.p-6.shadow').first();
}

function invoiceHeaderStatusSection(page: import('@playwright/test').Page) {
	return invoiceDetailCard(page).locator('div.flex.items-start.justify-between > div').first();
}

function invoiceTimelineGrid(page: import('@playwright/test').Page) {
	return invoiceDetailCard(page).locator(
		'div.mt-4.grid.grid-cols-3.gap-4.border-t.border-gray-200.pt-4.text-sm'
	);
}

async function expectInvoiceHeaderStatusBadge(
	page: import('@playwright/test').Page,
	statusLabel: string
): Promise<void> {
	const headerStatusSection = invoiceHeaderStatusSection(page);
	const statusBadge = headerStatusSection
		.locator('div.mt-2 > span.rounded-full.px-2\\.5.py-0\\.5.text-xs.font-medium')
		.filter({ hasText: new RegExp(`^${statusLabel}$`) });
	await expect(headerStatusSection.getByText(new RegExp(`^${statusLabel}$`))).toHaveCount(1);
	await expect(statusBadge).toHaveCount(1);
	await expect(statusBadge).toHaveText(new RegExp(`^${statusLabel}$`));
}

async function expectInvoiceTimelineLabelsWithValues(
	page: import('@playwright/test').Page
): Promise<void> {
	const timelineGrid = invoiceTimelineGrid(page);
	await expect(timelineGrid).toBeVisible();

	for (const label of ['Created', 'Finalized', 'Paid']) {
		const timelineColumn = timelineGrid.locator('div').filter({
			has: page.getByText(new RegExp(`^${label}$`))
		});
		await expect(timelineColumn).toHaveCount(1);
		await expect(timelineColumn.getByText(new RegExp(`^${label}$`))).toBeVisible();
		await expect(timelineColumn.locator('p').nth(1)).not.toHaveText(new RegExp(`^${label}$`));
		await expect(timelineColumn.locator('p').nth(1)).not.toHaveText(/^\s*$/);
	}
}

async function expectSessionExpiredRedirect(page: import('@playwright/test').Page): Promise<void> {
	await expect(page).toHaveURL(/\/login(?:\?reason=session_expired)?$/, { timeout: 20_000 });
	if (new URL(page.url()).searchParams.get('reason') === 'session_expired') {
		await expect(page.getByTestId('session-expired-banner')).toBeVisible({ timeout: 20_000 });
	}
}

async function assertExpiredSessionRedirect(page: import('@playwright/test').Page): Promise<void> {
	await page.goto('/dashboard/indexes');
	await expect(page.getByRole('heading', { name: 'Indexes' })).toBeVisible();

	await page.context().addCookies([
		{
			name: AUTH_COOKIE,
			value: 'expired-session-token',
			url: BASE_URL,
			httpOnly: true,
			sameSite: 'Lax'
		}
	]);

	await page.getByRole('button', { name: 'Create Index' }).click();
	await page.getByLabel('Index name').fill(`session-expired-${Date.now()}`);
	const regionRadios = page.getByRole('radio');
	if ((await regionRadios.count()) > 0) {
		await regionRadios.first().check();
	}
	await page.getByRole('button', { name: 'Create', exact: true }).click();

	await expectSessionExpiredRedirect(page);
}

test.describe('Fresh signup to paid invoice', () => {
	// Signup + verification + billing can take multiple async backend cycles.
	test.describe.configure({ retries: 0 });

	test('signs up, verifies email, reaches paid invoice evidence', async ({
		page,
		createFreshSignupIdentity,
		completeFreshSignupEmailVerification,
		arrangePaidInvoiceForFreshSignup,
		arrangeBillingDunningForFreshSignup,
		arrangeRefundedInvoiceForFreshSignup,
		adminSuspendCustomer,
		adminReactivateCustomer,
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
		await page.getByRole('checkbox', { name: /public beta terms/i }).check();
		await page.getByRole('button', { name: 'Sign Up' }).click();

		const signupAlert = page.getByRole('alert');
		await Promise.race([
			page.waitForURL(/\/dashboard/, { timeout: 20_000 }),
			signupAlert.waitFor({ state: 'visible', timeout: 20_000 })
		]).catch(() => undefined);

		if (!/\/dashboard/.test(page.url())) {
			const alertVisible = await signupAlert.isVisible().catch(() => false);
			const alertText = alertVisible ? ((await signupAlert.textContent())?.trim() ?? '') : '';
			if (isFreshSignupArrangePrerequisiteFailure(alertText)) {
				throwFreshSignupArrangeFailure({
					currentPath: page.url(),
					alertText
				});
			}

			throwFreshSignupArrangeFailure({
				currentPath: page.url(),
				alertText:
					alertText ||
					'Sign up did not reach /dashboard and no alert was visible within 20 seconds.'
			});
		}

		await expect(page).toHaveURL(/\/dashboard/, { timeout: 20_000 });
		await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible();

		const { verificationToken } = await completeFreshSignupEmailVerification(page, signup.email);
		await page.goto(`/verify-email/${verificationToken}`);
		await expect(page.getByRole('heading', { name: 'Verification Failed' })).toBeVisible({
			timeout: 20_000
		});
		await expect(page.getByText(/invalid or expired verification token/i)).toBeVisible();

		await loginWithFreshSignupCredentials(page, signup.email, signup.password);
		await page.goto('/dashboard');
		await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible();
		await assertDashboardRouteWalk(page);

		const paidInvoiceEvidence = await arrangePaidInvoiceForFreshSignup(signup.email, signup.password);

		await page.goto('/dashboard/billing/invoices');
		await expect(page.getByRole('heading', { name: 'Invoices' })).toBeVisible();
		const invoiceLink = page.locator(
			`a[href="/dashboard/billing/invoices/${paidInvoiceEvidence.invoiceId}"]`
		);
		await expect(invoiceLink).toBeVisible({ timeout: 30_000 });
		await invoiceLink.click();
		await expect(page).toHaveURL(
			new RegExp(`/dashboard/billing/invoices/${paidInvoiceEvidence.invoiceId}$`)
		);
		await expect(page.getByRole('heading', { name: 'Line Items' })).toBeVisible();
		await expectInvoiceHeaderStatusBadge(page, 'Paid');
		await expectInvoiceTimelineLabelsWithValues(page);
		await expect(invoiceDetailCard(page).getByText(/^Paid$/)).toHaveCount(2);
		expect(paidInvoiceEvidence.invoiceEmailDelivered).toBe(true);

		const dunningEvidence = await arrangeBillingDunningForFreshSignup(
			signup.email,
			signup.password,
			paidInvoiceEvidence.invoiceId
		);
		expect(dunningEvidence.dunningSubscriptionStatus).toBe('past_due');

		await page.goto('/dashboard/billing');
		await expect(page.getByRole('heading', { name: 'Billing' })).toBeVisible();
		await expect(page.getByTestId('subscription-recovery-banner')).toBeVisible();
		await expect(
			page.getByText('Payment failed for your subscription. Update your payment method to recover access.')
		).toBeVisible();
		await expect(page.getByRole('button', { name: 'Recover payment' })).toBeVisible();

		const refundEvidence = await arrangeRefundedInvoiceForFreshSignup(
			signup.email,
			signup.password,
			paidInvoiceEvidence.invoiceId
		);
		expect(refundEvidence.refundedInvoiceId).toBe(paidInvoiceEvidence.invoiceId);

		await page.goto('/dashboard/billing/invoices');
		await expect(page.getByRole('heading', { name: 'Invoices' })).toBeVisible();
		const refundedInvoiceRow = page
			.locator('tr')
			.filter({
				has: page.locator(`a[href="/dashboard/billing/invoices/${refundEvidence.refundedInvoiceId}"]`)
			})
			.first();
		await expect(refundedInvoiceRow).toBeVisible({ timeout: 30_000 });
		await expect(refundedInvoiceRow.getByText('Refunded')).toBeVisible();
		await refundedInvoiceRow.getByRole('link', { name: 'View' }).click();
		await expect(page).toHaveURL(
			new RegExp(`/dashboard/billing/invoices/${refundEvidence.refundedInvoiceId}$`)
		);
		await expect(page.getByRole('heading', { name: 'Line Items' })).toBeVisible();
		await expectInvoiceHeaderStatusBadge(page, 'Refunded');
		await expectInvoiceTimelineLabelsWithValues(page);

		await adminSuspendCustomer(paidInvoiceEvidence.customerId);
		try {
			await page.goto('/dashboard/billing');
			await expectSessionExpiredRedirect(page);
		} finally {
			await adminReactivateCustomer(paidInvoiceEvidence.customerId);
		}

		await loginWithFreshSignupCredentials(page, signup.email, signup.password);
		await assertExpiredSessionRedirect(page);
	});
});
