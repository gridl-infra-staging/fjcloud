/**
 * Shared remote-login + session-expiry recovery helpers used by billing specs
 * (`billing.spec.ts`, `billing_portal_payment_method_update.spec.ts`) and
 * fresh-signup billing proof (`signup_to_paid_invoice.spec.ts`).
 *
 * Single owner — do not copy these flows into spec files. Extend here.
 */
import { expect, type Page } from '@playwright/test';
import { isRemoteTargetMode, setAuthCookieForToken } from './fresh_signup_remote_bootstrap';
import type { LoginAsFn } from './fixtures';

const TRANSIENT_RATE_LIMIT_PATTERN = /too many requests/i;
const SESSION_EXPIRED_REASON = 'session_expired';

function isSessionExpiredUrl(urlString: string): boolean {
	const currentUrl = new URL(urlString);
	return (
		currentUrl.pathname === '/login' &&
		currentUrl.searchParams.get('reason') === SESSION_EXPIRED_REASON
	);
}

function sessionRecoveryFailure(billingPath: string, detail: string): Error {
	return new Error(`Session-expired recovery failed for ${billingPath}: ${detail}`);
}

/**
 * Log in via the UI with retry-on-rate-limit, falling back to remote
 * cookie-replay when the UI login flow cannot complete in remote-target mode.
 */
export async function loginWithFixtureCredentials(
	page: Page,
	email: string,
	password: string,
	loginAs: LoginAsFn
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
				throw new Error('Login was transiently rate-limited; retrying');
			}
			if (!isRemoteTargetMode()) {
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

/**
 * Navigate to any protected route and transparently recover if navigation
 * lands on `/login?reason=session_expired` in remote-target mode.
 */
export async function gotoPathWithSessionRecovery(
	page: Page,
	path: string,
	email: string,
	password: string,
	loginAs: LoginAsFn
): Promise<void> {
	await page.goto(path);
	if (!isSessionExpiredUrl(page.url())) {
		return;
	}
	if (!isRemoteTargetMode()) {
		throw sessionRecoveryFailure(
			path,
			'initial navigation hit /login?reason=session_expired but remote recovery is unavailable'
		);
	}

	const token = await loginAs(email, password);
	await setAuthCookieForToken(page, token);
	await page.goto(path);
	if (isSessionExpiredUrl(page.url())) {
		throw sessionRecoveryFailure(
			path,
			'navigation remained on /login?reason=session_expired after auth-cookie replay'
		);
	}
}

/**
 * Billing-path wrapper for readability in billing-only specs.
 */
export async function gotoBillingPageWithSessionRecovery(
	page: Page,
	email: string,
	password: string,
	loginAs: LoginAsFn
): Promise<void> {
	await gotoPathWithSessionRecovery(page, '/dashboard/billing', email, password, loginAs);
}
