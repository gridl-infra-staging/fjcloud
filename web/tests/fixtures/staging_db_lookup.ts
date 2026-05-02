/**
 * @module Staging DB lookup helper for the LB-2/LB-3 remote-target browser
 * lane.
 *
 * Mailpit doesn't exist on staging, and staging RDS is only reachable from
 * inside the staging VPC (the EC2 API host). This helper bridges that gap
 * by shelling out to scripts/launch/ssm_exec_staging.sh, which uses AWS
 * SSM RunShellScript to execute psql on the EC2 host where DATABASE_URL
 * is reachable.
 *
 * Used by web/tests/fixtures/fixtures.ts when
 * process.env.PLAYWRIGHT_TARGET_REMOTE === '1' to fetch fresh-signup
 * verification tokens directly from the customers table — equivalent to
 * what findVerificationTokenViaMailpit() does for the local lane.
 */
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..', '..', '..');
const SSM_EXEC_SCRIPT = path.join(REPO_ROOT, 'scripts', 'launch', 'ssm_exec_staging.sh');

// Allow only characters that legitimately appear in test-generated emails:
// alphanumerics, dot, dash, plus, underscore, and the @ separator. Anything
// outside this set is rejected to keep the SQL-literal interpolation safe.
// E2E identities are constructed by createFreshSignupIdentity() with seeds
// from Date.now() + Math.random() — strictly within this allowlist.
const SAFE_EMAIL_CHARS = /^[A-Za-z0-9._+\-@]+$/;

/**
 * Build the SQL query that reads a customer's verification token from the
 * staging DB. The email is embedded as a single-quoted literal after a
 * strict character allowlist check; we deliberately do NOT use libpq
 * parameter binding here because the outer transport is shell+psql and
 * piping bind params through that layer would add complexity for no
 * benefit when the input space is fully under our control.
 */
export function buildVerificationTokenLookupSql(email: string): string {
	if (!email || !SAFE_EMAIL_CHARS.test(email)) {
		throw new Error(
			`refusing to embed unsafe email into SQL literal: ${JSON.stringify(email)} ` +
				`(only [A-Za-z0-9._+-@] allowed)`
		);
	}
	return `SELECT email_verify_token FROM customers WHERE email = '${email}'`;
}

/**
 * Build the inner shell command that ssm_exec_staging.sh receives. This
 * sources the deployed env (where DATABASE_URL lives — populated by
 * generate_ssm_env.sh into /etc/fjcloud/env) and runs psql with strict
 * settings: -v ON_ERROR_STOP=1 fails fast on any SQL error, -tA gives
 * unaligned tuples-only output (one value per line, no header/padding)
 * so the caller can trim() and use directly.
 *
 * The SQL is wrapped in -tAc "..." on the outer shell, so embedded double
 * quotes in the SQL must be backslash-escaped to survive shell parsing.
 * Single quotes (the SQL-literal delimiter) need no escaping at the
 * shell layer.
 */
export function buildSsmStagingPsqlCommand(sql: string): string {
	const shellEscapedSql = sql.replace(/"/g, '\\"');
	return `source /etc/fjcloud/env && psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAc "${shellEscapedSql}"`;
}

/**
 * Parse psql -tA output that is expected to be a single column from at
 * most one matching row. Returns the trimmed value, an empty string if
 * no rows matched, or throws if the output looks malformed (multiple
 * rows, or a NULL marker we wouldn't want to silently treat as a value).
 */
export function parseSingleColumnSingleRowOutput(rawOutput: string): string {
	// psql -tA emits a trailing newline even for zero-row results. Split
	// and drop trailing empties so we can distinguish "0 rows" from
	// ">1 rows" cleanly.
	const lines = rawOutput.split('\n').filter((line) => line.length > 0);
	if (lines.length === 0) {
		return '';
	}
	if (lines.length > 1) {
		throw new Error(
			`expected single-row psql -tA output but got ${lines.length} non-empty lines: ${JSON.stringify(lines)}`
		);
	}
	const [value] = lines;
	if (value === '\\N') {
		throw new Error(
			`psql output contained a NULL marker '\\N'; refusing to interpret as a verification token`
		);
	}
	return value;
}

/**
 * Execute the given shell command on the staging EC2 host via SSM and
 * return stdout. Surfaces stderr in the thrown error so failures
 * (missing IAM perms, instance offline, psql error) are diagnosable
 * without re-running with debug flags.
 */
export function execSsmStagingShell(command: string): string {
	const result = spawnSync('bash', [SSM_EXEC_SCRIPT, command], {
		encoding: 'utf8',
		// 5 minutes covers SSM send-command + poll + psql round-trip even
		// on a slow staging host. The SSM wrapper itself has a 300s default.
		timeout: 5 * 60 * 1000,
		// Run from the repo root so the wrapper's relative paths resolve.
		cwd: REPO_ROOT
	});
	if (result.error) {
		throw new Error(`ssm_exec_staging.sh failed to spawn: ${result.error.message}`);
	}
	if (result.status !== 0) {
		throw new Error(
			`ssm_exec_staging.sh exited ${result.status}. stdout=${result.stdout?.trim() ?? ''} stderr=${result.stderr?.trim() ?? ''}`
		);
	}
	return result.stdout;
}

/**
 * Look up a customer's email verification token in the staging DB via
 * SSM-exec'd psql. Returns the plaintext token, or throws if the customer
 * row is missing or has no token (already verified).
 */
export async function findVerificationTokenViaStagingSsm(email: string): Promise<string> {
	const sql = buildVerificationTokenLookupSql(email);
	const command = buildSsmStagingPsqlCommand(sql);
	const stdout = execSsmStagingShell(command);
	const token = parseSingleColumnSingleRowOutput(stdout);
	if (!token) {
		throw new Error(
			`no email_verify_token row in staging customers table for email=${email}; ` +
				`either the signup did not reach the API or the token was already consumed`
		);
	}
	return token;
}
