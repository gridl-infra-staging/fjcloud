import { test as setup, expect } from '@playwright/test';
import { quoteSqlLiteral, runSqlWithPsqlFallback } from './postgres_psql_helper';

/** Verify the SQL output confirms exactly one customer row was email-verified. */
export function assertSingleVerifiedCustomer(output: string, email: string, transport: string): void {
	const lines = output
		.split('\n')
		.map((line) => line.trim())
		.filter(Boolean);
	if (lines[lines.length - 1] === '1') {
		return;
	}
	throw new Error(
		`Fresh signup email verification via ${transport} did not update exactly one row for ${email}. Output: ${output}`
	);
}

/** Mark the freshly signed-up local account as verified so onboarding can create an index. */
export function verifyFreshSignupEmail(email: string): void {
	const databaseUrl = process.env.DATABASE_URL;
	if (!databaseUrl) {
		throw new Error(
			'DATABASE_URL must be set for onboarding auth setup so the fresh signup can be email-verified before index creation.'
		);
	}

	const sql = [
		'UPDATE customers',
		'SET email_verified_at = COALESCE(email_verified_at, NOW()),',
		'    email_verify_token = NULL,',
		'    email_verify_expires_at = NULL,',
		'    updated_at = NOW()',
		`WHERE email = ${quoteSqlLiteral(email)}`,
		"  AND status != 'deleted';",
		'SELECT COUNT(*) FROM customers',
		`WHERE email = ${quoteSqlLiteral(email)}`,
		'  AND email_verified_at IS NOT NULL',
		"  AND status != 'deleted';",
	].join('\n');

	const output = runSqlWithPsqlFallback(
		databaseUrl,
		sql,
		'Fresh signup email verification failed before onboarding setup could proceed'
	);
	assertSingleVerifiedCustomer(output, email, 'psql');
}

export function registerFreshOnboardingAccount(
	setupName: string,
	storageStatePath: string
): void {
	setup(setupName, async ({ page }) => {
		const timestamp = Date.now();
		const name = `Onboarding Test ${timestamp}`;
		const email = `onboarding-test-${timestamp}@e2e.griddle.test`;
		const password = 'TestPassword123!';

		await page.goto('/signup');

		await page.getByLabel('Name').fill(name);
		await page.getByLabel('Email').fill(email);
		await page.getByLabel('Password', { exact: true }).fill(password);
		await page.getByLabel('Confirm Password').fill(password);
		await page.getByRole('button', { name: 'Sign Up' }).click();

		const signupAlert = page.getByRole('alert');
		await Promise.race([
			page.waitForURL(/\/dashboard/, { timeout: 15_000 }),
			signupAlert.waitFor({ state: 'visible', timeout: 15_000 }),
		]);

		if (!/\/dashboard/.test(page.url())) {
			const alertText = await signupAlert.textContent();
			throw new Error(
				`Signup setup failed before reaching /dashboard. Alert: "${alertText?.trim() ?? '(none)'}". ` +
				'Check API_URL, JWT_SECRET, and that the registration endpoint is accepting new users.'
			);
		}

		await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible();
		await expect(page.getByTestId('onboarding-banner')).toBeVisible({ timeout: 5_000 });

		verifyFreshSignupEmail(email);

		await page.context().storageState({ path: storageStatePath });
	});
}
