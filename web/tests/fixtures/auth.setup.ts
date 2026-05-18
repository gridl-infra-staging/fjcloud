/**
 * Auth setup — runs once before any test project that depends on it.
 *
 * Logs in through the real browser UI and saves the resulting browser state
 * (cookies) to .auth/user.json.  All customer-facing tests load that state
 * automatically so they start already authenticated.
 *
 * This file is an ARRANGE-phase shortcut (page.goto + form fill + storageState
 * are all allowed shortcuts per BROWSER_TESTING_STANDARDS_2.md).
 */

import { test as setup, expect, type Page } from '@playwright/test';
import {
	PLAYWRIGHT_STORAGE_STATE,
	resolveFixtureEnv,
	resolveRequiredFixtureUserCredentials
} from '../../playwright.config.contract';
import {
	FIXTURE_AUTH_API_RETRY_BUDGET_MS,
	bootstrapFixtureUserForKnownLoginFailure,
	formatFixtureSetupFailure,
	setupFailureDetailsFromError
} from './fixtures';

type CustomerLoginAttemptResult = {
	reachedDashboard: boolean;
	currentPath: string;
	alertText: string | null;
	responseStatus?: number;
	responseUrl?: string;
};

const LOGIN_SETTLE_TIMEOUT_MS = 20_000;
const DELAYED_ALERT_CAPTURE_TIMEOUT_MS = 5_000;
const AUTH_SETUP_TIMEOUT_MS =
	LOGIN_SETTLE_TIMEOUT_MS * 2 +
	FIXTURE_AUTH_API_RETRY_BUDGET_MS * 2 +
	DELAYED_ALERT_CAPTURE_TIMEOUT_MS +
	15_000;

setup.setTimeout(AUTH_SETUP_TIMEOUT_MS);

async function attemptCustomerLogin(
	page: Page,
	email: string,
	password: string
): Promise<CustomerLoginAttemptResult> {
	await page.goto('/login');
	await page.getByLabel('Email').fill(email);
	await page.getByLabel('Password').fill(password);

	const loginResponsePromise = page
		.waitForResponse(
			(response) =>
				response.request().method() === 'POST' && response.url().includes('/auth/login'),
			{ timeout: LOGIN_SETTLE_TIMEOUT_MS }
		)
		.catch(() => null);

	await page.getByRole('button', { name: /log in/i }).click();

	const loginAlert = page.getByRole('alert');
	await Promise.race([
		page.waitForURL(/\/dashboard/, { timeout: LOGIN_SETTLE_TIMEOUT_MS }),
		loginAlert.waitFor({ state: 'visible', timeout: LOGIN_SETTLE_TIMEOUT_MS })
	]).catch(() => undefined);

	const loginResponse = await loginResponsePromise;
	const reachedDashboard = /\/dashboard/.test(page.url());
	let alertText = reachedDashboard ? null : await loginAlert.textContent().catch(() => null);
	if (!reachedDashboard && !alertText?.trim()) {
		await loginAlert
			.waitFor({ state: 'visible', timeout: DELAYED_ALERT_CAPTURE_TIMEOUT_MS })
			.catch(() => undefined);
		alertText = await loginAlert.textContent().catch(() => null);
	}

	return {
		reachedDashboard,
		currentPath: page.url(),
		alertText,
		responseStatus: loginResponse?.status(),
		responseUrl: loginResponse?.url()
	};
}

function toFailureAlertText(attempt: CustomerLoginAttemptResult, bootstrapAttempted: boolean): string | null {
	if (!bootstrapAttempted) {
		return attempt.alertText;
	}

	const normalizedAlertText = attempt.alertText?.trim() || '(none)';
	return `${normalizedAlertText} (after fixture self-bootstrap retry)`;
}

function toBootstrapFailureAlertText(
	attempt: CustomerLoginAttemptResult,
	error: unknown
): string {
	const normalizedAlertText = attempt.alertText?.trim() || '(none)';
	return `${normalizedAlertText} (fixture self-bootstrap failed: ${setupFailureDetailsFromError(error)})`;
}

setup('authenticate as customer', async ({ page }) => {
	const { email, password } = resolveRequiredFixtureUserCredentials(process.env);
	const fixtureEnv = resolveFixtureEnv(process.env);
	let finalLoginAttempt = await attemptCustomerLogin(page, email, password);
	let bootstrapAttempted = false;

	if (!finalLoginAttempt.reachedDashboard) {
		try {
			const bootstrapResult = await bootstrapFixtureUserForKnownLoginFailure({
				apiUrl: fixtureEnv.apiUrl,
				email,
				password,
				currentPath: finalLoginAttempt.currentPath,
				alertText: finalLoginAttempt.alertText,
				responseStatus: finalLoginAttempt.responseStatus,
				responseUrl: finalLoginAttempt.responseUrl
			});

			if (bootstrapResult.bootstrapped) {
				bootstrapAttempted = true;
				finalLoginAttempt = await attemptCustomerLogin(page, email, password);
			}
		} catch (error) {
			throw new Error(
				formatFixtureSetupFailure({
					setupName: 'Customer login setup',
					expectedPath: '/dashboard',
					currentPath: finalLoginAttempt.currentPath,
					apiUrl: fixtureEnv.apiUrl,
					adminKey: fixtureEnv.adminKey,
					alertText: toBootstrapFailureAlertText(finalLoginAttempt, error),
					responseStatus: finalLoginAttempt.responseStatus,
					responseUrl: finalLoginAttempt.responseUrl
				})
			);
		}
	}

	if (!finalLoginAttempt.reachedDashboard) {
		throw new Error(
			formatFixtureSetupFailure({
				setupName: 'Customer login setup',
				expectedPath: '/dashboard',
				currentPath: finalLoginAttempt.currentPath,
				apiUrl: fixtureEnv.apiUrl,
				adminKey: fixtureEnv.adminKey,
				alertText: toFailureAlertText(finalLoginAttempt, bootstrapAttempted),
				responseStatus: finalLoginAttempt.responseStatus,
				responseUrl: finalLoginAttempt.responseUrl
			})
		);
	}

	await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible();

	await page.context().storageState({ path: PLAYWRIGHT_STORAGE_STATE.user });
});
