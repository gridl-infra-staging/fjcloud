import { test as setup, expect } from '@playwright/test';
import { REMOTE_TARGET_OPT_IN_ENV, resolveFixtureEnv } from '../../playwright.config.contract';
import { quoteSqlLiteral, runSqlWithPsqlFallback } from './postgres_psql_helper';
import {
	findVerificationTokenViaStagingSsm,
	parseSingleColumnSingleRowOutput
} from './staging_db_lookup';
import { ensureLocalSharedVmInventoryForRegion } from './fixtures';

const REMOTE_VERIFY_MAX_RETRIES = 10;

function getRemoteVerifyRetryDelayMs(attempt: number, retryAfterHeader: string | null): number {
	const retryAfterSeconds = Number(retryAfterHeader ?? '');
	const retryAfterMs =
		Number.isFinite(retryAfterSeconds) && retryAfterSeconds > 0 ? retryAfterSeconds * 1000 : 0;
	return Math.max(retryAfterMs, Math.min(2000 * (attempt + 1), 10_000));
}

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

function buildSafeVerifyEmailTransportFailureMessage(error: unknown): string {
	const detail = error instanceof Error ? error.message : String(error);
	return (
		'Fresh signup email verification failed before onboarding setup could proceed. ' +
		`transport_error=${detail}`
	);
}

function assertRecognizedLocalVerificationState(state: string, email: string): void {
	if (state === 'already_verified' || state === 'needs_verification') {
		return;
	}
	throw new Error(
		`Fresh signup email verification fixture found unexpected local customer state for ${email}: ${state || '(missing row)'}.`
	);
}

async function verifyFreshSignupEmailViaRemoteApi(email: string): Promise<void> {
	const fixtureEnv = resolveFixtureEnv(process.env);
	const verificationToken = await findVerificationTokenViaStagingSsm(email);
	for (let attempt = 0; attempt < REMOTE_VERIFY_MAX_RETRIES; attempt += 1) {
		let response: Response;
		try {
			response = await fetch(`${fixtureEnv.apiUrl}/auth/verify-email`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({ token: verificationToken })
			});
		} catch (error) {
			throw new Error(buildSafeVerifyEmailTransportFailureMessage(error));
		}
		if (response.ok) {
			return;
		}
		if (response.status === 429) {
			await new Promise((resolve) =>
				setTimeout(resolve, getRemoteVerifyRetryDelayMs(attempt, response.headers.get('retry-after')))
			);
			continue;
		}
		throw new Error(buildSafeVerifyEmailFailureMessage(response));
	}
	throw new Error(
		'Fresh signup email verification failed before onboarding setup could proceed. exhausted retries after 429 rate limiting'
	);
}

/** Mark the freshly signed-up account as verified so onboarding can create an index. */
export async function verifyFreshSignupEmail(email: string): Promise<void> {
	if (process.env[REMOTE_TARGET_OPT_IN_ENV] === '1') {
		await verifyFreshSignupEmailViaRemoteApi(email);
		return;
	}

	const databaseUrl = process.env.DATABASE_URL;
	if (!databaseUrl) {
		throw new Error(
			'DATABASE_URL must be set for onboarding auth setup so the fresh signup can be email-verified before index creation.'
		);
	}

	const quotedEmail = quoteSqlLiteral(email);
	const localStateOutput = runSqlWithPsqlFallback(
		databaseUrl,
		[
			'SELECT CASE',
			"  WHEN email_verified_at IS NOT NULL AND email_verify_token IS NULL THEN 'already_verified'",
			"  WHEN email_verified_at IS NULL AND email_verify_token IS NOT NULL THEN 'needs_verification'",
			"  WHEN email_verified_at IS NULL AND email_verify_token IS NULL THEN 'unverified_missing_token'",
			"  WHEN email_verified_at IS NOT NULL AND email_verify_token IS NOT NULL THEN 'verified_with_stale_token'",
			'END',
			'FROM customers',
			`WHERE email = ${quotedEmail}`,
			"  AND status != 'deleted'",
			'LIMIT 1;'
		].join('\n'),
		'Fresh signup local verification-state lookup failed before onboarding setup could proceed'
	);
	const localVerificationState = parseSingleColumnSingleRowOutput(localStateOutput);
	assertRecognizedLocalVerificationState(localVerificationState, email);
	if (localVerificationState === 'already_verified') {
		return;
	}

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

type EnsureLocalSharedVmInventory = (region: string) => Promise<void>;

export async function arrangeFreshOnboardingProjectPrerequisites(
	email: string,
	ensureLocalSharedVmInventory: EnsureLocalSharedVmInventory = ensureLocalSharedVmInventoryForRegion
): Promise<void> {
	await verifyFreshSignupEmail(email);
	await ensureLocalSharedVmInventory(resolveFixtureEnv(process.env).testRegion);
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
		// Whichever branch loses the race keeps waiting and then rejects on timeout.
		// Swallow both rejections so the race always settles and the URL check below
		// reports the actionable diagnostic instead of an opaque Playwright timeout.
		await Promise.race([
			page.waitForURL(/\/console/, { timeout: 15_000, waitUntil: 'commit' }).catch(() => {}),
			signupAlert.waitFor({ state: 'visible', timeout: 15_000 }).catch(() => {})
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

		await arrangeFreshOnboardingProjectPrerequisites(email);

		await page.context().storageState({ path: storageStatePath });
	});
}
