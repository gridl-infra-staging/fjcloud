/**
 * Full stack — Auth end effects
 *
 * Exercises fresh signup, verification, and reset-token side effects from blank state.
 */

import {
	test,
	expect,
	findResetTokenViaMailpit,
	LOCAL_AUTO_VERIFIED_TOKEN_PREFIX
} from '../../fixtures/fixtures';

test.use({ storageState: { cookies: [], origins: [] } });

test.describe('Reset password end-effect', () => {
	test('valid reset token redeems password and allows login with new credentials @p0_coverage', async ({
		page,
		createFreshSignupIdentity,
		arrangeFreshSignupToDashboard
	}) => {
		test.setTimeout(60_000);
		const signup = createFreshSignupIdentity();
		const arrangeResult = await arrangeFreshSignupToDashboard(page, signup);
		if (arrangeResult.prerequisiteFailureMessage) {
			test.skip(
				true,
				`reset-password prerequisite unavailable: ${arrangeResult.prerequisiteFailureMessage}`
			);
			return;
		}

		await page.context().clearCookies();
		await page.goto('/forgot-password');
		await page.getByLabel('Email').fill(signup.email);
		await page.getByRole('button', { name: 'Send Reset Link' }).click();
		await expect(page.getByText('If an account exists with that email')).toBeVisible({
			timeout: 5_000
		});

		const resetToken = await findResetTokenViaMailpit(signup.email);

		await page.goto(`/reset-password/${resetToken}`);
		await expect(page.getByRole('heading', { name: 'Reset your password' })).toBeVisible();

		const newPassword = 'ResetNewPassword456!';
		await page.getByLabel('New Password', { exact: true }).fill(newPassword);
		await page.getByLabel('Confirm New Password').fill(newPassword);
		await page.getByRole('button', { name: 'Reset Password' }).click();

		const successAlert = page.getByRole('alert');
		await expect(successAlert).toBeVisible({ timeout: 10_000 });
		await expect(successAlert).toContainText('Your password has been reset successfully');

		await page.getByRole('link', { name: 'Log in' }).click();
		await expect(page).toHaveURL(/\/login/, { timeout: 10_000 });

		await page.getByLabel('Email').fill(signup.email);
		await page.getByLabel('Password').fill(newPassword);
		await page.getByRole('button', { name: 'Log In' }).click();
		await expect(page).toHaveURL(/\/console/, { timeout: 15_000 });
	});
});

test.describe('Verify email end-effect', () => {
	test('valid verification token shows success heading and login CTA @p0_coverage', async ({
		page,
		createFreshSignupIdentity,
		completeFreshSignupEmailVerification
	}) => {
		const signup = createFreshSignupIdentity();

		await page.goto('/signup');
		await page.getByLabel('Name').fill(signup.name);
		await page.getByLabel('Email').fill(signup.email);
		await page.getByLabel('Password', { exact: true }).fill(signup.password);
		await page.getByLabel('Confirm Password').fill(signup.password);
		await page.getByRole('button', { name: 'Sign Up' }).click();

		await Promise.race([
			page.waitForURL(/\/console/, { timeout: 20_000 }),
			page.getByRole('alert').waitFor({ state: 'visible', timeout: 20_000 })
		]).catch(() => undefined);

		const { verificationToken } = await completeFreshSignupEmailVerification(
			page,
			signup.email,
			signup.password
		);
		if (verificationToken.startsWith(LOCAL_AUTO_VERIFIED_TOKEN_PREFIX)) {
			test.skip(true, 'local stack auto-verifies emails; no real Mailpit token available');
			return;
		}

		const verifyResult = page.getByTestId('verify-result');
		await expect(verifyResult).toBeVisible({ timeout: 10_000 });
		await expect(verifyResult).toHaveAttribute('data-success', 'true');
		await expect(page.getByRole('heading', { name: 'Email verified' })).toBeVisible();
		await expect(page.getByRole('link', { name: 'Log in to continue' })).toHaveAttribute(
			'href',
			'/login'
		);
	});
});

test.describe('Forgot password email delivery', () => {
	test('forgot-password email is delivered with a valid reset link @p0_coverage', async ({
		page,
		createFreshSignupIdentity,
		arrangeFreshSignupToDashboard
	}) => {
		test.setTimeout(60_000);
		const signup = createFreshSignupIdentity();
		const arrangeResult = await arrangeFreshSignupToDashboard(page, signup);
		if (arrangeResult.prerequisiteFailureMessage) {
			test.skip(
				true,
				`forgot-password email delivery prerequisite unavailable: ${arrangeResult.prerequisiteFailureMessage}`
			);
			return;
		}

		await page.context().clearCookies();
		await page.goto('/forgot-password');
		await page.getByLabel('Email').fill(signup.email);
		await page.getByRole('button', { name: 'Send Reset Link' }).click();
		await expect(page.getByText('If an account exists with that email')).toBeVisible({
			timeout: 5_000
		});

		const resetToken = await findResetTokenViaMailpit(signup.email);
		expect(resetToken).toBeTruthy();
		expect(resetToken.length).toBeGreaterThan(0);
	});
});
