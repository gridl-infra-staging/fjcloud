/**
 * Full stack — Auth form API effects
 *
 * Exercises login and duplicate-signup outcomes that require a local API stack.
 */

import { test, expect } from '../../fixtures/fixtures';
import {
	isTransientRateLimitMessage,
	loginThroughUiWithRetry,
	submitDuplicateSignupWithRetry
} from './auth_flow_helpers';

test.use({ storageState: { cookies: [], origins: [] } });

const GENERIC_LOGIN_FAILURE_PATTERN = /invalid (email or password|credentials)/i;

test.describe('Login page API effects', () => {
	test('wrong password shows error alert and stays on /login', async ({ page }) => {
		await page.goto('/login');

		await page.getByLabel('Email').fill(process.env.E2E_USER_EMAIL ?? 'test@example.com');
		await page.getByLabel('Password').fill('definitely-wrong-password-xyz987');
		await page.getByRole('button', { name: 'Log In' }).click();

		await expect(page.getByRole('alert')).toBeVisible({ timeout: 5_000 });
		await expect(page.getByRole('alert')).toContainText(GENERIC_LOGIN_FAILURE_PATTERN);
		await expect(page).toHaveURL(/\/login/);
	});

	test('non-existent email uses the same generic failure treatment as wrong password', async ({
		page
	}) => {
		const missingEmail = `missing-${Date.now()}@e2e.griddle.test`;
		await expect(async () => {
			await page.goto('/login');
			await page.getByLabel('Email').fill(missingEmail);
			await page.getByLabel('Password').fill('definitely-wrong-password-xyz987');
			await page.getByRole('button', { name: 'Log In' }).click();

			const loginAlert = page.getByRole('alert');
			await expect(loginAlert).toBeVisible({ timeout: 5_000 });
			const alertText = (await loginAlert.textContent())?.trim() ?? '';
			if (isTransientRateLimitMessage(alertText)) {
				throw new Error('Login was transiently rate-limited; retrying generic-failure assertion');
			}

			await expect(loginAlert).toContainText(GENERIC_LOGIN_FAILURE_PATTERN);
			await expect(loginAlert).not.toContainText(missingEmail);
			await expect(page).toHaveURL(/\/login/);
		}).toPass({
			intervals: [1_000, 2_000, 3_000, 4_000, 5_000],
			timeout: 45_000
		});
	});

	test('successful login redirects to the dashboard', async ({ page }) => {
		await loginThroughUiWithRetry(
			page,
			process.env.E2E_USER_EMAIL ?? '',
			process.env.E2E_USER_PASSWORD ?? ''
		);
		await expect(page.getByRole('heading', { name: 'Console' })).toBeVisible();
	});
});

test.describe('Signup page API effects', () => {
	test('duplicate email signup uses a generic failure and stays on /signup', async ({
		page,
		createUser
	}) => {
		const duplicateEmail = `duplicate-signup-${Date.now()}@e2e.griddle.test`;
		await createUser(duplicateEmail, 'TestPassword123!', 'Existing Signup User');

		const formAlert = await submitDuplicateSignupWithRetry(page, duplicateEmail, 'validpassword1');
		await expect(formAlert).toContainText(
			'We could not create your account. Please check your details and try again.'
		);
		await expect(formAlert).not.toContainText(/already exists/i);
		await expect(formAlert).not.toContainText(duplicateEmail);
		await expect(page).toHaveURL(/\/signup/);
	});
});
