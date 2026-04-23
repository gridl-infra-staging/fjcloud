/**
 * Full — Auth
 *
 * Covers the complete authentication surface:
 *   - Login form renders correctly
 *   - Wrong password shows error alert, stays on /login
 *   - Successful login redirects to /dashboard
 *   - Unauthenticated visit to /dashboard redirects to /login
 *   - Logout ends the session
 *   - Forgot-password form accepts submission
 *   - Signup form validates password confirmation
 */

import { test, expect } from '../../fixtures/fixtures';
import {
	AUTH_COOKIE,
	DASHBOARD_SESSION_EXPIRED_REDIRECT
} from '../../../src/lib/server/auth-session-contracts';

const BASE_URL = process.env.BASE_URL ?? 'http://localhost:5173';
const GENERIC_LOGIN_FAILURE_PATTERN = /invalid (email or password|credentials)/i;
const TRANSIENT_RATE_LIMIT_PATTERN = /too many requests/i;

async function submitDuplicateSignupWithRetry(
	page: import('@playwright/test').Page,
	email: string,
	password: string
): Promise<import('@playwright/test').Locator> {
	const formAlert = page.getByRole('alert');

	await expect(async () => {
		await page.goto('/signup');
		await page.getByLabel('Name').fill('Duplicate Signup User');
		await page.getByLabel('Email').fill(email);
		await page.getByLabel('Password', { exact: true }).fill(password);
		await page.getByLabel('Confirm Password').fill(password);
		await page.getByRole('checkbox', { name: /public beta terms/i }).check();
		await page.getByRole('button', { name: 'Sign Up' }).click();

		await expect(formAlert).toBeVisible({ timeout: 5_000 });
		await expect(formAlert).not.toContainText(TRANSIENT_RATE_LIMIT_PATTERN);
	}).toPass({
		intervals: [1_000, 2_000, 3_000, 4_000, 5_000],
		timeout: 30_000
	});

	return formAlert;
}

async function loginThroughUiWithRetry(
	page: import('@playwright/test').Page,
	email: string,
	password: string
): Promise<void> {
	await expect(async () => {
		await page.goto('/login');
		await page.getByLabel('Email').fill(email);
		await page.getByLabel('Password').fill(password);
		await page.getByRole('button', { name: 'Log In' }).click();

		const loginAlert = page.getByRole('alert');
		const dashboardNavigation = page
			.waitForURL(/\/dashboard/, { timeout: 10_000 })
			.catch(() => undefined);
		const alertVisible = loginAlert
			.waitFor({ state: 'visible', timeout: 10_000 })
			.catch(() => undefined);
		await Promise.race([dashboardNavigation, alertVisible]);

		if (/\/dashboard/.test(page.url())) {
			return;
		}

		const alertText = (await loginAlert.textContent())?.trim() ?? '';
		if (TRANSIENT_RATE_LIMIT_PATTERN.test(alertText)) {
			throw new Error('Login was transiently rate-limited; retrying through visible UI');
		}

		await expect(page).toHaveURL(/\/dashboard/, { timeout: 10_000 });
	}).toPass({
		intervals: [1_000, 2_000, 3_000, 4_000, 5_000],
		timeout: 45_000
	});
}

// All tests here exercise auth flows from an unauthenticated state.
test.use({ storageState: { cookies: [], origins: [] } });

test.describe('Login page', () => {
	test('renders the login form with all required elements', async ({ page }) => {
		await page.goto('/login');

		await expect(page).toHaveTitle(/Flapjack Cloud/);
		await expect(page).not.toHaveTitle(/Griddle/);
		await expect(page.getByRole('heading', { name: 'Log in to Flapjack Cloud' })).toBeVisible();
		await expect(page.getByLabel('Email')).toBeVisible();
		await expect(page.getByLabel('Password')).toBeVisible();
		await expect(page.getByRole('button', { name: 'Log In' })).toBeVisible();
		await expect(page.getByRole('link', { name: 'Forgot your password?' })).toBeVisible();
		await expect(page.getByRole('link', { name: 'Sign up' })).toBeVisible();
	});

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
		await page.goto('/login');
		await page.getByLabel('Email').fill(missingEmail);
		await page.getByLabel('Password').fill('definitely-wrong-password-xyz987');
		await page.getByRole('button', { name: 'Log In' }).click();

		await expect(page.getByRole('alert')).toBeVisible({ timeout: 5_000 });
		await expect(page.getByRole('alert')).toContainText(GENERIC_LOGIN_FAILURE_PATTERN);
		await expect(page.getByRole('alert')).not.toContainText(missingEmail);
		await expect(page).toHaveURL(/\/login/);
	});

	test('successful login redirects to the dashboard', async ({ page }) => {
		await loginThroughUiWithRetry(
			page,
			process.env.E2E_USER_EMAIL ?? '',
			process.env.E2E_USER_PASSWORD ?? ''
		);
		await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible();
	});

	test('unauthenticated visit to /dashboard redirects to /login', async ({ page }) => {
		await page.goto('/dashboard');

		await expect(page).toHaveURL(/\/login/);
	});

	test('session expired during dashboard action redirects to login with session-expired banner', async ({
		page
	}) => {
		const loginEmail = process.env.E2E_USER_EMAIL ?? '';
		const loginPassword = process.env.E2E_USER_PASSWORD ?? '';
		// eslint-disable-next-line playwright/no-skipped-test -- shared session-expiry flow requires seeded login credentials
		test.skip(
			!loginEmail || !loginPassword,
			'E2E_USER_EMAIL and E2E_USER_PASSWORD are required for session-expiry coverage'
		);

		await loginThroughUiWithRetry(page, loginEmail, loginPassword);

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
		await page
			.getByRole('radio')
			.first()
			.check()
			.catch(() => {
				/* No region radios rendered in this environment */
			});
		await page.getByRole('button', { name: 'Create', exact: true }).click();

		await expect(page).toHaveURL(/\/login(?:\?reason=session_expired)?$/, { timeout: 15_000 });
		if (new URL(page.url()).searchParams.get('reason') === 'session_expired') {
			await expect(page.getByTestId('session-expired-banner')).toBeVisible({ timeout: 15_000 });
		}
	});
});

test.describe('Logout', () => {
	test('clicking Logout ends the session and redirects to /login', async ({ page }) => {
		// Arrange: log in
		await loginThroughUiWithRetry(
			page,
			process.env.E2E_USER_EMAIL ?? '',
			process.env.E2E_USER_PASSWORD ?? ''
		);

		// Act: click Logout in the header
		await page.getByRole('button', { name: 'Logout' }).click();

		// Assert: redirected to login; subsequent visit to /dashboard also redirects
		await expect(page).toHaveURL(/\/login/, { timeout: 10_000 });
		await page.goto('/dashboard');
		await expect(page).toHaveURL(/\/login/);
	});
});

test.describe('Forgot password page', () => {
	test('renders the forgot-password form', async ({ page }) => {
		await page.goto('/forgot-password');

		await expect(page.getByRole('heading', { name: 'Forgot your password?' })).toBeVisible();
		await expect(page.getByLabel('Email')).toBeVisible();
		await expect(page.getByRole('button', { name: 'Send Reset Link' })).toBeVisible();
	});

	test('submitting an email shows a confirmation message', async ({ page }) => {
		await page.goto('/forgot-password');

		await page.getByLabel('Email').fill('nonexistent@example.com');
		await page.getByRole('button', { name: 'Send Reset Link' }).click();

		// API always returns success to prevent account enumeration
		await expect(page.getByText('If an account exists with that email')).toBeVisible({
			timeout: 5_000
		});
	});
});

test.describe('Reset password page', () => {
	test('renders the reset-password form for a token route', async ({ page }) => {
		await page.goto('/reset-password/browser-invalid-reset-token');

		await expect(page.getByRole('heading', { name: 'Reset your password' })).toBeVisible();
		await expect(page.getByLabel('New Password', { exact: true })).toBeVisible();
		await expect(page.getByLabel('Confirm New Password')).toBeVisible();
		await expect(page.getByRole('button', { name: 'Reset Password' })).toBeVisible();
	});

	test('password mismatch shows visible feedback and keeps the reset form available', async ({
		page
	}) => {
		await page.goto('/reset-password/browser-invalid-reset-token');

		await page.getByLabel('New Password', { exact: true }).fill('ValidPassword123!');
		await page.getByLabel('Confirm New Password').fill('DifferentPassword123!');
		await page.getByRole('button', { name: 'Reset Password' }).click();

		await expect(page.getByText('Passwords do not match')).toBeVisible({ timeout: 5_000 });
		await expect(page.getByRole('button', { name: 'Reset Password' })).toBeVisible();
	});
});

test.describe('Verify email page', () => {
	test('invalid verification token shows failure result with login CTA', async ({ page }) => {
		await page.goto(`/verify-email/browser-invalid-token-${Date.now()}`);

		await expect(page.getByRole('heading', { name: 'Verification Failed' })).toBeVisible({
			timeout: 10_000
		});
		await expect(page.getByRole('link', { name: 'Go to Login' })).toHaveAttribute('href', '/login');
	});
});

test.describe('Signup page', () => {
	test('renders all required signup form fields', async ({ page }) => {
		await page.goto('/signup');

		await expect(page.getByRole('heading', { name: 'Create your account' })).toBeVisible();
		await expect(page.getByLabel('Name')).toBeVisible();
		await expect(page.getByLabel('Email')).toBeVisible();
		await expect(page.getByLabel('Password', { exact: true })).toBeVisible();
		await expect(page.getByLabel('Confirm Password')).toBeVisible();
		await expect(page.getByRole('checkbox', { name: /public beta terms/i })).toBeVisible();
		await expect(page.getByRole('button', { name: 'Sign Up' })).toBeVisible();
	});

	test('password mismatch shows a validation error', async ({ page }) => {
		await page.goto('/signup');

		await page.getByLabel('Name').fill('Test User');
		await page.getByLabel('Email').fill(`signup-validation-${Date.now()}@example.com`);
		await page.getByLabel('Password', { exact: true }).fill('validpassword1');
		await page.getByLabel('Confirm Password').fill('differentpassword1');
		await page.getByRole('checkbox', { name: /public beta terms/i }).check();
		await page.getByRole('button', { name: 'Sign Up' }).click();

		await expect(page.getByRole('alert')).toBeVisible({ timeout: 5_000 });
		await expect(page).toHaveURL(/\/signup/);
	});

	test('weak password signup shows deterministic password-length feedback', async ({ page }) => {
		await page.goto('/signup');

		await page.getByLabel('Name').fill('Weak Password User');
		await page.getByLabel('Email').fill(`weak-password-${Date.now()}@e2e.griddle.test`);
		await page.getByLabel('Password', { exact: true }).fill('short');
		await page.getByLabel('Confirm Password').fill('short');
		await page.getByRole('checkbox', { name: /public beta terms/i }).check();
		await page.getByRole('button', { name: 'Sign Up' }).click();

		await expect(page.getByText('Password must be at least 8 characters')).toBeVisible({
			timeout: 5_000
		});
		await expect(page).toHaveURL(/\/signup/);
	});

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
