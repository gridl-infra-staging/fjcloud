import { expect, test } from '../../fixtures/fixtures';

test.use({ storageState: { cookies: [], origins: [] } });

test.describe('Auth trust states', () => {
	test('Forgot password page keeps generic resend success without cooldown guidance', async ({
		page
	}) => {
		let resendIntentRequests = 0;

		await page.route('**/forgot-password', async (route, request) => {
			if (!request.postData()?.includes('intent=resend')) {
				await route.continue();
				return;
			}
			resendIntentRequests += 1;

			await route.fulfill({
				status: 200,
				contentType: 'application/json',
				body: JSON.stringify({
					type: 'success',
					status: 200,
					data: '[{"sent":1,"email":2,"resendStatus":3},true,"trust-state@example.com","resent"]'
				})
			});
		});

		await page.goto('/forgot-password');
		await page.getByLabel('Email').fill('trust-state@example.com');
		await page.getByRole('button', { name: 'Send Reset Link' }).click();

		await expect(page.getByTestId('forgot-password-success-message')).toBeVisible();
		await page.getByTestId('forgot-password-resend-button').click();

		await expect(page.getByTestId('forgot-password-resend-cooldown-message')).toHaveCount(0);
		await expect(page.getByTestId('forgot-password-success-message')).toBeVisible();
		expect(resendIntentRequests).toBe(1);
	});

	test('Forgot password page shows cooldown guidance for resend auth-rate-limit 429', async ({
		page
	}) => {
		await page.route('**/forgot-password', async (route, request) => {
			if (!request.postData()?.includes('intent=resend')) {
				await route.continue();
				return;
			}

			await route.fulfill({
				status: 200,
				contentType: 'application/json',
				body: JSON.stringify({
					type: 'failure',
					status: 429,
					data: '[{"sent":1,"email":2,"resendStatus":3,"retryAfterSeconds":4},true,"trust-state@example.com","cooldown",90]'
				})
			});
		});

		await page.goto('/forgot-password');
		await page.getByLabel('Email').fill('trust-state@example.com');
		await page.getByRole('button', { name: 'Send Reset Link' }).click();

		await expect(page.getByTestId('forgot-password-success-message')).toBeVisible();
		await page.getByTestId('forgot-password-resend-button').click();

		await expect(page.getByTestId('forgot-password-resend-cooldown-message')).toContainText(
			'Please wait 90 seconds before requesting another reset link.'
		);
	});

	test('Forgot password page shows delivery-failure guidance for resend 503', async ({ page }) => {
		await page.route('**/forgot-password', async (route, request) => {
			if (!request.postData()?.includes('intent=resend')) {
				await route.continue();
				return;
			}

			await route.fulfill({
				status: 200,
				contentType: 'application/json',
				body: JSON.stringify({
					type: 'failure',
					status: 503,
					data: '[{"sent":1,"email":2,"resendStatus":3},true,"trust-state@example.com","delivery_failure"]'
				})
			});
		});

		await page.goto('/forgot-password');
		await page.getByLabel('Email').fill('trust-state@example.com');
		await page.getByRole('button', { name: 'Send Reset Link' }).click();

		await expect(page.getByTestId('forgot-password-success-message')).toBeVisible();
		await page.getByTestId('forgot-password-resend-button').click();

		await expect(page.getByTestId('forgot-password-resend-delivery-failure-message')).toBeVisible();
		await expect(page.getByTestId('forgot-password-resend-delivery-failure-message')).toContainText(
			'We could not send a new reset email right now. Please try again shortly.'
		);
	});

	test('Reset password page shows recovery CTA for invalid or expired token', async ({ page }) => {
		await page.route('**/reset-password/**', async (route, request) => {
			if (request.method() !== 'POST') {
				await route.continue();
				return;
			}

			await route.fulfill({
				status: 200,
				contentType: 'application/json',
				body: JSON.stringify({
					type: 'failure',
					status: 400,
					data: '[{"errors":1,"recoveryAction":3},{"form":2},"invalid or expired reset token","invalid_or_expired_token"]'
				})
			});
		});

		await page.goto('/reset-password/browser-invalid-reset-token');
		await page.getByLabel('New Password', { exact: true }).fill('ValidPassword123!');
		await page.getByLabel('Confirm New Password').fill('ValidPassword123!');
		await page.getByRole('button', { name: 'Reset Password' }).click();

		await expect(page.getByTestId('reset-password-form-error')).toContainText(
			'invalid or expired reset token'
		);
		await expect(page.getByTestId('reset-password-request-new-email')).toHaveAttribute(
			'href',
			'/forgot-password'
		);
	});
});
