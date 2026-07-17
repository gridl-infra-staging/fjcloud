import { expect, type Locator, type Page } from '@playwright/test';

const TRANSIENT_RATE_LIMIT_PATTERN = /too many requests/i;
const CONSOLE_URL_PATTERN = /\/console/;
const UI_RETRY_INTERVALS_MS = [1_000, 2_000, 3_000, 4_000, 5_000];

export function isTransientRateLimitMessage(message: string): boolean {
	return TRANSIENT_RATE_LIMIT_PATTERN.test(message);
}

async function readAlertText(alert: Locator): Promise<string> {
	return (await alert.textContent())?.trim() ?? '';
}

export async function loginThroughUiWithRetry(
	page: Page,
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
			.waitForURL(CONSOLE_URL_PATTERN, { timeout: 10_000 })
			.catch(() => undefined);
		const alertVisible = loginAlert
			.waitFor({ state: 'visible', timeout: 10_000 })
			.catch(() => undefined);
		await Promise.race([dashboardNavigation, alertVisible]);

		if (CONSOLE_URL_PATTERN.test(page.url())) {
			return;
		}

		const alertText = await readAlertText(loginAlert);
		if (isTransientRateLimitMessage(alertText)) {
			throw new Error('Login was transiently rate-limited; retrying through visible UI');
		}

		await expect(page).toHaveURL(CONSOLE_URL_PATTERN, { timeout: 10_000 });
	}).toPass({
		intervals: UI_RETRY_INTERVALS_MS,
		timeout: 45_000
	});
}

export async function submitDuplicateSignupWithRetry(
	page: Page,
	email: string,
	password: string
): Promise<Locator> {
	const formAlert = page.getByRole('alert');

	await expect(async () => {
		await page.goto('/signup');
		await page.getByLabel('Name').fill('Duplicate Signup User');
		await page.getByLabel('Email').fill(email);
		await page.getByLabel('Password', { exact: true }).fill(password);
		await page.getByLabel('Confirm Password').fill(password);
		await page.getByRole('button', { name: 'Sign Up' }).click();

		await expect(formAlert).toBeVisible({ timeout: 5_000 });
		const alertText = await readAlertText(formAlert);
		expect(isTransientRateLimitMessage(alertText)).toBe(false);
	}).toPass({
		intervals: UI_RETRY_INTERVALS_MS,
		timeout: 30_000
	});

	return formAlert;
}
