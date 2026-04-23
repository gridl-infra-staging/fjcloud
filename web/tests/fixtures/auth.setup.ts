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

import { test as setup, expect } from '@playwright/test';
import {
	PLAYWRIGHT_STORAGE_STATE,
	resolveFixtureEnv,
	resolveRequiredFixtureUserCredentials
} from '../../playwright.config.contract';
import { formatFixtureSetupFailure } from './fixtures';

setup('authenticate as customer', async ({ page }) => {
	const { email, password } = resolveRequiredFixtureUserCredentials(process.env);
	const fixtureEnv = resolveFixtureEnv(process.env);

	await page.goto('/login');

	await page.getByLabel('Email').fill(email);
	await page.getByLabel('Password').fill(password);

	const loginResponsePromise = page
		.waitForResponse(
			(response) =>
				response.request().method() === 'POST' && response.url().includes('/auth/login'),
			{ timeout: 10_000 }
		)
		.catch(() => null);

	await page.getByRole('button', { name: 'Log in' }).click();

	const loginAlert = page.getByRole('alert');
	// Wait for either success redirect or form-level failure alert.
	await Promise.race([
		page.waitForURL(/\/dashboard/, { timeout: 10_000 }),
		loginAlert.waitFor({ state: 'visible', timeout: 10_000 })
	]).catch(() => undefined);

	if (!/\/dashboard/.test(page.url())) {
		const [alertText, loginResponse] = await Promise.all([
			loginAlert.textContent().catch(() => null),
			loginResponsePromise
		]);

		throw new Error(
			formatFixtureSetupFailure({
				setupName: 'Customer login setup',
				expectedPath: '/dashboard',
				currentPath: page.url(),
				apiUrl: fixtureEnv.apiUrl,
				adminKey: fixtureEnv.adminKey,
				alertText,
				responseStatus: loginResponse?.status(),
				responseUrl: loginResponse?.url()
			})
		);
	}

	await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible();

	await page.context().storageState({ path: PLAYWRIGHT_STORAGE_STATE.user });
});
