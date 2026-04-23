/**
 * Admin auth setup — runs once before any admin test project.
 *
 * Logs into the admin panel through the real browser UI using the ADMIN_KEY
 * env var and saves the resulting browser state to .auth/admin.json.
 */

import { test as setup } from '@playwright/test';
import {
	PLAYWRIGHT_STORAGE_STATE,
	resolveFixtureEnv,
	resolveRequiredFixtureAdminKey
} from '../../playwright.config.contract';
import { formatFixtureSetupFailure } from './fixtures';

setup('authenticate as admin', async ({ page }) => {
	const adminKey = resolveRequiredFixtureAdminKey(process.env);
	const fixtureEnv = resolveFixtureEnv(process.env);

	await page.goto('/admin/login');

	await page.getByLabel('Admin key').fill(adminKey);

	const loginResponsePromise = page
		.waitForResponse(
			(response) =>
				response.request().method() === 'POST' && response.url().includes('/admin/login'),
			{ timeout: 10_000 }
		)
		.catch(() => null);

	await page.getByRole('button', { name: 'Log in' }).click();

	const loginAlert = page.getByRole('alert');
	await Promise.race([
		page.waitForURL(/\/admin\/fleet/, { timeout: 10_000 }),
		loginAlert.waitFor({ state: 'visible', timeout: 10_000 })
	]).catch(() => undefined);

	if (!/\/admin\/fleet/.test(page.url())) {
		const [alertText, loginResponse] = await Promise.all([
			loginAlert.textContent().catch(() => null),
			loginResponsePromise
		]);
		throw new Error(
			formatFixtureSetupFailure({
				setupName: 'Admin login setup',
				expectedPath: '/admin/fleet',
				currentPath: page.url(),
				apiUrl: fixtureEnv.apiUrl,
				adminKey: fixtureEnv.adminKey,
				alertText,
				responseStatus: loginResponse?.status(),
				responseUrl: loginResponse?.url()
			})
		);
	}

	await page.context().storageState({ path: PLAYWRIGHT_STORAGE_STATE.admin });
});
