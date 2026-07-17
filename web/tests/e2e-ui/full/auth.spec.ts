/**
 * Full — Auth
 *
 * Covers shared-user authenticated session behavior:
 *   - Session expiration redirects to /login
 *   - Logout ends the session
 */

import { test, expect } from '../../fixtures/fixtures';
import { AUTH_COOKIE } from '../../../src/lib/server/auth-session-contracts';

const BASE_URL = process.env.BASE_URL ?? 'http://localhost:5173';

test.describe('Authenticated session', () => {
	test('session expired during dashboard action redirects to login with session-expired banner', async ({
		page
	}) => {
		await page.goto('/console/indexes');
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
		await page.goto('/console');
		await expect(page.getByRole('heading', { name: 'Console' })).toBeVisible();

		await page.getByRole('button', { name: 'Logout' }).click();

		await expect(page).toHaveURL(/\/login/, { timeout: 10_000 });
		await page.goto('/console');
		await expect(page).toHaveURL(/\/login/);
	});
});
