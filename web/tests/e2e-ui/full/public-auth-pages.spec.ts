/**
 * Full public — Auth pages
 *
 * Exercises unauthenticated auth form surfaces from a blank browser state.
 */

import { test, expect } from '../../fixtures/fixtures';

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
		await expect(page.getByRole('link', { name: 'Sign up' })).toHaveCount(0);
	});

	test('renders OAuth links with expected hrefs outside the login form', async ({ page }) => {
		await page.goto('/login');

		const googleOAuthLink = page.getByTestId('oauth-button-google');
		const githubOAuthLink = page.getByTestId('oauth-button-github');

		await expect(googleOAuthLink).toBeVisible();
		await expect(googleOAuthLink).toContainText('Continue with Google');
		await expect(googleOAuthLink).toHaveAttribute('href', /\/auth\/oauth\/google\/start$/);
		await expect(githubOAuthLink).toBeVisible();
		await expect(githubOAuthLink).toContainText('Continue with GitHub');
		await expect(githubOAuthLink).toHaveAttribute('href', /\/auth\/oauth\/github\/start$/);

		await expect(
			googleOAuthLink.evaluate((element) => element.closest('form'))
		).resolves.toBeNull();
		await expect(
			githubOAuthLink.evaluate((element) => element.closest('form'))
		).resolves.toBeNull();

		await page.getByRole('button', { name: 'Log In' }).click();
		await expect(page).toHaveURL(/\/login(?:\?.*)?$/);
	});
});

test.describe('Protected customer routes', () => {
	test('unauthenticated visit to /console redirects to /login', async ({ page }) => {
		await page.goto('/console');

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

	test('reset-password password toggle reveals fields in place', async ({ page }) => {
		await page.goto('/reset-password/browser-invalid-reset-token');

		const newPassword = page.getByLabel('New Password', { exact: true });
		const confirmPassword = page.getByLabel('Confirm New Password');

		await newPassword.fill('ValidPassword123!');
		await expect(newPassword).toHaveAttribute('type', 'password');
		await page.getByRole('button', { name: 'Show password' }).first().click();
		await expect(newPassword).toHaveAttribute('type', 'text');
		await expect(newPassword).toHaveValue('ValidPassword123!');
		await expect(confirmPassword).toHaveAttribute('type', 'password');
	});
});

test.describe('Verify email page', () => {
	test('invalid verification token shows failure result with login CTA', async ({ page }) => {
		await page.goto(`/verify-email/browser-invalid-token-${Date.now()}`);

		await expect(page.getByRole('heading', { name: 'We could not verify your email' })).toBeVisible(
			{
				timeout: 10_000
			}
		);
		await expect(
			page.getByText(
				'The link may be expired or already used. Log in to request a fresh verification email.'
			)
		).toBeVisible();
		await expect(page.getByRole('link', { name: 'Log in to continue' })).toHaveAttribute(
			'href',
			'/login'
		);
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
		await expect(page.getByText('Use at least 8 characters.')).toBeVisible();
		await expect(page.getByRole('checkbox', { name: /public beta terms/i })).toHaveCount(0);
		await expect(page.getByRole('button', { name: 'Sign Up' })).toBeVisible();
	});

	test('renders OAuth links with expected hrefs outside the signup form', async ({ page }) => {
		await page.goto('/signup');

		const googleOAuthLink = page.getByTestId('oauth-button-google');
		const githubOAuthLink = page.getByTestId('oauth-button-github');

		await expect(googleOAuthLink).toBeVisible();
		await expect(googleOAuthLink).toContainText('Continue with Google');
		await expect(googleOAuthLink).toHaveAttribute('href', /\/auth\/oauth\/google\/start$/);
		await expect(githubOAuthLink).toBeVisible();
		await expect(githubOAuthLink).toContainText('Continue with GitHub');
		await expect(githubOAuthLink).toHaveAttribute('href', /\/auth\/oauth\/github\/start$/);

		await expect(
			googleOAuthLink.evaluate((element) => element.closest('form'))
		).resolves.toBeNull();
		await expect(
			githubOAuthLink.evaluate((element) => element.closest('form'))
		).resolves.toBeNull();

		await page.getByRole('button', { name: 'Sign Up' }).click();
		await expect(page).toHaveURL(/\/signup(?:\?.*)?$/);
	});

	test('password mismatch shows a validation error', async ({ page }) => {
		await page.goto('/signup');

		await page.getByLabel('Name').fill('Test User');
		await page.getByLabel('Email').fill(`signup-validation-${Date.now()}@example.com`);
		await page.getByLabel('Password', { exact: true }).fill('validpassword1');
		await page.getByLabel('Confirm Password').fill('differentpassword1');
		await page.getByRole('button', { name: 'Sign Up' }).click();

		await expect(page.getByRole('alert')).toHaveText('Passwords do not match', { timeout: 5_000 });
		await expect(page).toHaveURL(/\/signup/);
	});

	test('signup password toggle reveals fields in place', async ({ page }) => {
		await page.goto('/signup');

		const password = page.getByLabel('Password', { exact: true });
		const confirmPassword = page.getByLabel('Confirm Password');

		await password.fill('validpassword1');
		await expect(password).toHaveAttribute('type', 'password');
		await page.getByRole('button', { name: 'Show password' }).first().click();
		await expect(password).toHaveAttribute('type', 'text');
		await expect(password).toHaveValue('validpassword1');
		await expect(confirmPassword).toHaveAttribute('type', 'password');
	});

	test('weak password signup shows deterministic password-length feedback', async ({ page }) => {
		await page.goto('/signup');

		await page.getByLabel('Name').fill('Weak Password User');
		await page.getByLabel('Email').fill(`weak-password-${Date.now()}@e2e.griddle.test`);
		await page.getByLabel('Password', { exact: true }).fill('short');
		await page.getByLabel('Confirm Password').fill('short');
		await page.getByRole('button', { name: 'Sign Up' }).click();

		await expect(page.getByText('Password must be at least 8 characters')).toBeVisible({
			timeout: 5_000
		});
		await expect(page).toHaveURL(/\/signup/);
	});
});
