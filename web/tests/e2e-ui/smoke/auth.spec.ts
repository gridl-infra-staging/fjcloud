/**
 * Smoke — Auth
 *
 * Critical path: a returning customer can log in and reach the dashboard.
 * Stored auth state is not used here so we always exercise the real login flow.
 */

import { test, expect } from '@playwright/test';

// This smoke test intentionally opts out of the pre-loaded storageState
// so it always verifies the live login path.
test.use({ storageState: { cookies: [], origins: [] } });

test('login with valid credentials reaches the dashboard', async ({ page }) => {
	const email = process.env.E2E_USER_EMAIL ?? '';
	const password = process.env.E2E_USER_PASSWORD ?? '';

	await page.goto('/login');

	await expect(page).toHaveTitle(/Flapjack Cloud/);
	await expect(page).not.toHaveTitle(/Griddle/);
	await expect(page.getByRole('heading', { name: 'Log in to Flapjack Cloud' })).toBeVisible();

	await page.getByLabel('Email').fill(email);
	await page.getByLabel('Password').fill(password);
	await page.getByRole('button', { name: 'Log in' }).click();

	await expect(page).toHaveURL(/\/console/, { timeout: 10_000 });
	await expect(page.getByRole('heading', { name: 'Console' })).toBeVisible();
});

test.describe('OAuth route shape', () => {
	test('login OAuth start routes return 302 or 501 and never 500', async ({ page }) => {
		const providers = [
			{ name: 'google', buttonTestId: 'oauth-button-google' },
			{ name: 'github', buttonTestId: 'oauth-button-github' }
		] as const;

		for (const provider of providers) {
			// Re-load /login per provider because clicking the OAuth link navigates
			// away from the login page (to the synthetic 200 served by route.fulfill).
			await page.goto('/login');

			const oauthLink = page.getByTestId(provider.buttonTestId);
			await expect(oauthLink).toBeVisible();
			await expect(oauthLink).toHaveAttribute(
				'href',
				new RegExp(`/auth/oauth/${provider.name}/start$`)
			);

			const startPathPattern = `**/auth/oauth/${provider.name}/start`;
			let observedStatus: number | undefined;
			let observedLocation: string | undefined;

			// Intercept the OAuth start request, fetch the real backend response so we
			// observe its true status, then fulfill the browser with a synthetic 200 that
			// has no Location header. That way the page never redirects to the live
			// provider (accounts.google.com / github.com) but we still prove the backend
			// route shape (302 or 501, never 500). This is the browser-safe "capture and
			// abort follow-on navigation" path the Stage 5 checklist requires.
			await page.route(startPathPattern, async (route) => {
				const apiResponse = await route.fetch({ maxRedirects: 0 });
				observedStatus = apiResponse.status();
				observedLocation = apiResponse.headers()['location'];
				await route.fulfill({
					status: 200,
					contentType: 'text/plain',
					body: `oauth-start-route-shape-probe:${provider.name}:${observedStatus}`
				});
			});

			await oauthLink.click();
			await expect
				.poll(() => observedStatus, {
					message: `${provider.name} OAuth start route did not respond`
				})
				.not.toBeUndefined();
			await page.unroute(startPathPattern);

			const status = observedStatus!;
			expect(
				[302, 501],
				`${provider.name} OAuth start route status should be 302 or 501 (got ${status})`
			).toContain(status);
			expect(status).not.toBe(500);

			// Location header is required on 302 (proves a real redirect was emitted)
			// and must be absent on 501 (NotImplemented carries no redirect target).
			// Asserting both branches in one expectation avoids a conditional expect.
			expect(
				Boolean(observedLocation),
				`${provider.name} OAuth start: Location header should be present iff status is 302 (status=${status})`
			).toBe(status === 302);
		}
	});
});
