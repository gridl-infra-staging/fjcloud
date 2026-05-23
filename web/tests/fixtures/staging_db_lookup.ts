import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..', '..', '..');
const SSM_EXEC_SCRIPT = path.join(REPO_ROOT, 'scripts', 'launch', 'ssm_exec_staging.sh');
const SSM_STAGING_LOOKUP_TIMEOUT_SECONDS = 90;
const SSM_STAGING_LOOKUP_SPAWN_TIMEOUT_MS = 120 * 1000;

// Allow only characters that legitimately appear in test-generated emails:
// alphanumerics, dot, dash, plus, underscore, and the @ separator. Anything
// outside this set is rejected to keep the SQL-literal interpolation safe.
// E2E identities are constructed by createFreshSignupIdentity() with seeds
// from Date.now() + Math.random() — strictly within this allowlist.
const SAFE_EMAIL_CHARS = /^[A-Za-z0-9._+\-@]+$/;
const SAFE_IDENTIFIER_CHARS = /^[A-Za-z0-9_-]+$/;

export type StagingPaidInvoiceEvidence = {
	stagingCustomerId: string;
	stagingInvoiceId: string;
	stagingInvoiceStatus: string;
	stagingInvoicePeriodStart: string;
};

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

function parseSingleRowPipeSeparatedOutput(
	rawOutput: string,
	expectedColumns: number
): string[] | null {
	const lines = rawOutput.split('\n').filter((line) => line.length > 0);
	if (lines.length === 0) {
		return null;
	}
	if (lines.length > 1) {
		throw new Error(
			`expected single-row psql -tA output but got ${lines.length} non-empty lines: ${JSON.stringify(lines)}`
		);
	}

	const columns = lines[0].split('|');
	if (columns.length !== expectedColumns) {
		throw new Error(
			`expected ${expectedColumns} psql columns but got ${columns.length}: ${JSON.stringify(columns)}`
		);
	}
	if (columns.some((value) => value === '\\N')) {
		throw new Error(`psql output contained NULL markers: ${JSON.stringify(columns)}`);
	}
	return columns;
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
		// Keep DB evidence probes well below the lane watchdog so hangs surface
		// as explicit staging_db_lookup errors rather than generic spec timeouts.
		timeout: SSM_STAGING_LOOKUP_SPAWN_TIMEOUT_MS,
		env: {
			...process.env,
			SSM_EXEC_TIMEOUT_SECONDS: String(SSM_STAGING_LOOKUP_TIMEOUT_SECONDS)
		},
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

function buildPaidInvoiceEvidenceLookupSql(email: string, invoiceId: string): string {
	if (!email || !SAFE_EMAIL_CHARS.test(email)) {
		throw new Error(
			`refusing to embed unsafe email into SQL literal: ${JSON.stringify(email)} ` +
				`(only [A-Za-z0-9._+-@] allowed)`
		);
	}
	if (!invoiceId || !SAFE_IDENTIFIER_CHARS.test(invoiceId)) {
		throw new Error(
			`refusing to embed unsafe invoice id into SQL literal: ${JSON.stringify(invoiceId)} ` +
				`(only [A-Za-z0-9_-] allowed)`
		);
	}

	return [
		'SELECT c.id::text, i.id::text, i.status::text, i.period_start::text',
		'FROM customers c',
		'JOIN invoices i ON i.customer_id = c.id',
		`WHERE c.email = '${email}'`,
		`AND i.id::text = '${invoiceId}'`
	].join(' ');
}

export async function findPaidInvoiceEvidenceViaStagingSsm(
	email: string,
	invoiceId: string
): Promise<StagingPaidInvoiceEvidence> {
	const sql = buildPaidInvoiceEvidenceLookupSql(email, invoiceId);
	const command = buildSsmStagingPsqlCommand(sql);
	const stdout = execSsmStagingShell(command);
	const columns = parseSingleRowPipeSeparatedOutput(stdout, 4);
	if (!columns) {
		throw new Error(
			`no staging paid-invoice row for email=${email} invoice_id=${invoiceId}; ` +
				`either billing did not write the expected invoice or the row is not visible yet`
		);
	}

	const [stagingCustomerId, stagingInvoiceId, stagingInvoiceStatus, stagingInvoicePeriodStart] =
		columns;
	return {
		stagingCustomerId,
		stagingInvoiceId,
		stagingInvoiceStatus,
		stagingInvoicePeriodStart
	};
}
