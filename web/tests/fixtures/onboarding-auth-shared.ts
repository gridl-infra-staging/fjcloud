import { test as setup, expect } from '@playwright/test';
import { REMOTE_TARGET_OPT_IN_ENV, resolveFixtureEnv } from '../../playwright.config.contract';
import { quoteSqlLiteral, runSqlWithPsqlFallback } from './postgres_psql_helper';
import { findVerificationTokenViaStagingSsm } from './staging_db_lookup';

/** Verify the SQL output confirms exactly one customer row was email-verified. */
export function assertSingleVerifiedCustomer(
	output: string,
	email: string,
	transport: string
): void {
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

function buildSafeVerifyEmailFailureMessage(response: Response): string {
	const requestId =
		response.headers.get('x-request-id') ?? response.headers.get('x-amzn-requestid') ?? '';
	return (
		'Fresh signup email verification failed before onboarding setup could proceed. ' +
		`status=${response.status}${requestId ? ` request_id=${requestId}` : ''}`
	);
}

/** Mark the freshly signed-up account as verified so onboarding can create an index. */
export async function verifyFreshSignupEmail(email: string): Promise<void> {
	if (process.env[REMOTE_TARGET_OPT_IN_ENV] === '1') {
		const fixtureEnv = resolveFixtureEnv(process.env);
		const verificationToken = await findVerificationTokenViaStagingSsm(email);
		const response = await fetch(`${fixtureEnv.apiUrl}/auth/verify-email`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ token: verificationToken })
		});
		if (!response.ok) {
			throw new Error(buildSafeVerifyEmailFailureMessage(response));
		}
		return;
	}

	const databaseUrl = process.env.DATABASE_URL;
	if (!databaseUrl) {
		throw new Error(
			'DATABASE_URL must be set for onboarding auth setup so the fresh signup can be email-verified before index creation.'
		);
	}

	const quotedEmail = quoteSqlLiteral(email);
	const sql = [
		'WITH updated AS (',
		'  UPDATE customers',
		'  SET email_verified_at = NOW(),',
		'      email_verify_token = NULL,',
		'      email_verify_expires_at = NULL,',
		'      updated_at = NOW()',
		`  WHERE email = ${quotedEmail}`,
		"    AND status != 'deleted'",
		'    AND email_verified_at IS NULL',
		'    AND email_verify_token IS NOT NULL',
		'  RETURNING 1',
		')',
		'SELECT COUNT(*) FROM updated;'
	].join('\n');

	const output = runSqlWithPsqlFallback(
		databaseUrl,
		sql,
		'Fresh signup email verification failed before onboarding setup could proceed'
	);
	assertSingleVerifiedCustomer(output, email, 'psql');
}

export function registerFreshOnboardingAccount(setupName: string, storageStatePath: string): void {
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
			page.waitForURL(/\/console/, { timeout: 15_000 }),
			signupAlert.waitFor({ state: 'visible', timeout: 15_000 })
		]);

		if (!/\/console/.test(page.url())) {
			const alertText = await signupAlert.textContent();
			throw new Error(
				`Signup setup failed before reaching /console. Alert: "${alertText?.trim() ?? '(none)'}". ` +
					'Check API_URL, JWT_SECRET, and that the registration endpoint is accepting new users.'
			);
		}

		await expect(page.getByRole('heading', { name: 'Console' })).toBeVisible();
		await expect(page.getByTestId('onboarding-banner')).toBeVisible({ timeout: 5_000 });

		await verifyFreshSignupEmail(email);

		await page.context().storageState({ path: storageStatePath });
	});
}
