import { test as setup, expect } from '@playwright/test';
import { execFileSync, spawnSync } from 'child_process';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..', '..', '..');

type PostgresConnection = {
	host: string;
	port: string;
	user: string;
	password: string;
	database: string;
};

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

function parsePostgresConnection(databaseUrl: string): PostgresConnection {
	const parsed = new URL(databaseUrl);
	const database = parsed.pathname.replace(/^\//, '');
	return {
		host: parsed.hostname || '127.0.0.1',
		port: parsed.port || '5432',
		user: decodeURIComponent(parsed.username),
		password: decodeURIComponent(parsed.password),
		database,
	};
}

function quoteSqlLiteral(value: string): string {
	return `'${value.replace(/'/g, "''")}'`;
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

	const connection = parsePostgresConnection(databaseUrl);
	const psqlArgs = ['-v', 'ON_ERROR_STOP=1', '-tA', '-c', sql];
	const psqlConnectionArgs = [
		'-h',
		connection.host,
		'-p',
		connection.port,
		'-U',
		connection.user,
		'-d',
		connection.database,
	];
	const hostPsql = spawnSync('psql', [...psqlConnectionArgs, ...psqlArgs], {
		cwd: REPO_ROOT,
		encoding: 'utf8',
		env: {
			...process.env,
			PGPASSWORD: connection.password,
			PSQLRC: '/dev/null',
		},
	});

	if (hostPsql.status === 0) {
		assertSingleVerifiedCustomer(hostPsql.stdout, email, 'host psql');
		return;
	}

	if (hostPsql.error && hostPsql.error.name !== 'Error') {
		throw hostPsql.error;
	}

	if (hostPsql.error?.message.includes('ENOENT')) {
		let dockerPsqlOutput: string;
		try {
			dockerPsqlOutput = execFileSync(
				'docker',
				[
					'compose',
					'exec',
					'-T',
					'-e',
					'PGPASSWORD',
					'-e',
					'PSQLRC',
					'postgres',
					'psql',
					'-U',
					connection.user,
					'-d',
					connection.database,
					...psqlArgs,
				],
				{
					cwd: REPO_ROOT,
					encoding: 'utf8',
					env: {
						...process.env,
						PGPASSWORD: connection.password,
						PSQLRC: '/dev/null',
					},
					stdio: 'pipe',
				},
			);
		} catch (dockerError: unknown) {
			const detail = dockerError instanceof Error ? dockerError.message : String(dockerError);
			throw new Error(
				'psql is not installed and docker compose fallback also failed. ' +
				'Resolution: either install psql (e.g. `brew install libpq`) or ' +
				'ensure `docker compose exec postgres psql` is available. ' +
				`Docker error: ${detail}`
			);
		}
		assertSingleVerifiedCustomer(dockerPsqlOutput, email, 'docker compose psql');
		return;
	}

	throw new Error(
		`Fresh signup email verification failed before onboarding setup could proceed. stderr: ${hostPsql.stderr || '(none)'}`
	);
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
