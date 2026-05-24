// LB-2/LB-3 — unit tests for the SSM-based staging DB lookup helper used
// by the remote-target browser lane to read fresh-signup verification
// tokens directly from staging RDS (Mailpit doesn't exist on staging, and
// staging RDS is only reachable from the EC2 host via SSM exec).
//
// These tests cover the PURE pieces of the helper (SQL construction,
// shell-command construction, SQL-injection rejection). The actual SSM
// exec path is integration-only and exercised by running the Playwright
// signup spec against deployed staging.
import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import {
	buildCustomerStatusLookupSql,
	buildSsmStagingPsqlCommand,
	buildVerificationTokenLookupSql,
	parseSingleColumnSingleRowOutput,
	parseSingleRowPipeSeparatedOutput
} from '../../tests/fixtures/staging_db_lookup';

describe('staging DB lookup helper (LB-2/LB-3)', () => {
	it('keeps fallback DB lookup ownership in staging_db_lookup.ts only', () => {
		const stagingLookupSource = readFileSync(
			join(process.cwd(), 'tests/fixtures/staging_db_lookup.ts'),
			'utf8'
		);
		const signupSpecSource = readFileSync(
			join(process.cwd(), 'tests/e2e-ui/full/signup_to_paid_invoice.spec.ts'),
			'utf8'
		);
		const fixtureSource = readFileSync(join(process.cwd(), 'tests/fixtures/fixtures.ts'), 'utf8');

		expect(stagingLookupSource).toMatch(/\bbuildVerificationTokenLookupSql\b/);
		expect(stagingLookupSource).toMatch(/\bbuildSsmStagingPsqlCommand\b/);
		expect(stagingLookupSource).toMatch(/\bexecSsmStagingShell\b/);
		expect(stagingLookupSource).toMatch(/\bfindPaidInvoiceEvidenceViaStagingSsm\b/);
		expect(stagingLookupSource).toMatch(/\bJOIN\s+invoices\b/i);
		expect(fixtureSource).not.toMatch(/\bbuildVerificationTokenLookupSql\b/);
		expect(fixtureSource).not.toMatch(/\bbuildSsmStagingPsqlCommand\b/);
		expect(fixtureSource).not.toMatch(/\bexecSsmStagingShell\b/);
		expect(fixtureSource).not.toMatch(/\bspawnSync\b/);
		expect(fixtureSource).not.toMatch(/\bFROM\s+invoices\b/i);
		expect(signupSpecSource).not.toMatch(/\bspawnSync\b/);
		expect(signupSpecSource).not.toMatch(/\bFROM\s+invoices\b/i);
	});

	it('bounds staging SSM lookup timeout below lane watchdog budget', () => {
		const stagingLookupSource = readFileSync(
			join(process.cwd(), 'tests/fixtures/staging_db_lookup.ts'),
			'utf8'
		);

		expect(stagingLookupSource).toMatch(/const\s+SSM_STAGING_LOOKUP_TIMEOUT_SECONDS\s*=\s*90/);
		expect(stagingLookupSource).toMatch(
			/const\s+SSM_STAGING_LOOKUP_SPAWN_TIMEOUT_MS\s*=\s*120\s*\*\s*1000/
		);
		expect(stagingLookupSource).toMatch(
			/SSM_EXEC_TIMEOUT_SECONDS:\s*String\(\s*SSM_STAGING_LOOKUP_TIMEOUT_SECONDS\s*\)/
		);
		expect(stagingLookupSource).toMatch(/timeout:\s*SSM_STAGING_LOOKUP_SPAWN_TIMEOUT_MS/);
	});

	describe('buildVerificationTokenLookupSql', () => {
		it('builds a parameterless SELECT with the email embedded as a quoted literal', () => {
			expect(buildVerificationTokenLookupSql('e2e-fresh-signup-1234@e2e.griddle.test')).toBe(
				"SELECT email_verify_token FROM customers WHERE email = 'e2e-fresh-signup-1234@e2e.griddle.test'"
			);
		});

		it('rejects emails containing single quotes (SQL injection guard)', () => {
			expect(() => buildVerificationTokenLookupSql("evil'; DROP TABLE customers;--")).toThrow(
				/refusing to embed unsafe email/i
			);
		});

		it('rejects emails containing backslashes (escape-injection guard)', () => {
			expect(() => buildVerificationTokenLookupSql('back\\slash@example.com')).toThrow(
				/refusing to embed unsafe email/i
			);
		});

		it('rejects empty email', () => {
			expect(() => buildVerificationTokenLookupSql('')).toThrow(/refusing to embed unsafe email/i);
		});

		it('rejects emails containing whitespace (which would smuggle SQL via line breaks)', () => {
			expect(() => buildVerificationTokenLookupSql('a@b.com\nDROP')).toThrow(
				/refusing to embed unsafe email/i
			);
		});
	});

	describe('buildSsmStagingPsqlCommand', () => {
		it('wraps SQL in a shell command that sources /etc/fjcloud/env and runs psql', () => {
			const sql = "SELECT email_verify_token FROM customers WHERE email = 'a@b.com'";
			const command = buildSsmStagingPsqlCommand(sql);
			expect(command).toContain('source /etc/fjcloud/env');
			expect(command).toContain('psql "$DATABASE_URL"');
			expect(command).toContain('-v ON_ERROR_STOP=1');
			// -tA gives unaligned tuples-only output (one value per line, no
			// header, no padding) so the caller can trim() and use directly.
			expect(command).toContain('-tA');
			expect(command).toContain(sql);
		});

		it('escapes embedded double-quotes in the SQL so the outer shell -tAc string survives', () => {
			// Single quotes in SQL literals are normal and must NOT be escaped.
			// Only double quotes need shell-escaping because the SQL is wrapped
			// in -tAc "..." on the outer shell.
			const sql = `SELECT 'literal "with-quotes"' FROM customers`;
			const command = buildSsmStagingPsqlCommand(sql);
			// The outer shell sees the SQL inside double quotes, so embedded
			// double quotes must be backslash-escaped to survive shell parsing.
			expect(command).toContain('\\"with-quotes\\"');
		});
	});

	describe('parseSingleColumnSingleRowOutput', () => {
		it('returns the trimmed single line of -tA output', () => {
			expect(parseSingleColumnSingleRowOutput('abcd1234efgh\n')).toBe('abcd1234efgh');
		});

		it('returns empty-string indicator when psql found no rows (handled by caller)', () => {
			// psql -tA returns an empty string when 0 rows match. The wrapper
			// helper preserves this so the caller can decide whether "no
			// verification token in DB" is an error or "already verified".
			expect(parseSingleColumnSingleRowOutput('')).toBe('');
			expect(parseSingleColumnSingleRowOutput('\n')).toBe('');
		});

		it('throws when output contains multiple non-empty lines (multiple matching rows is unexpected)', () => {
			expect(() => parseSingleColumnSingleRowOutput('row1\nrow2\n')).toThrow(
				/expected single-row.*got 2/i
			);
		});

		it('throws when output contains an embedded NULL marker', () => {
			// psql -tA renders NULL as empty string by default, but if a caller
			// changes \pset null, NULLs could surface as a literal "\N" or
			// configured marker. We'd rather fail loud than misinterpret.
			expect(() => parseSingleColumnSingleRowOutput('\\N')).toThrow(/null marker/i);
		});
	});

	// Stage 2 Seam Gaps (see web/tests/e2e-ui/full/system_proof_gaps.md →
	// "## Stage 2 Seam Gaps"): account/auth/onboarding/admin/customer-detail
	// specs need a customer-row readback by email. The parser shape already
	// exists internally; Stage 2 promotes it to a shared seam and adds the
	// customer-status SQL builder so future callers do not inline psql or
	// add a parallel lookup module.

	describe('parseSingleRowPipeSeparatedOutput (Stage 2 shared seam)', () => {
		it('splits a single pipe-separated -tA row into the expected column count', () => {
			const columns = parseSingleRowPipeSeparatedOutput(
				'00000000-0000-0000-0000-000000000001|active|cus_stripe_123\n',
				3
			);
			expect(columns).toEqual(['00000000-0000-0000-0000-000000000001', 'active', 'cus_stripe_123']);
		});

		it('returns null when zero rows matched (so callers can distinguish no-row from malformed)', () => {
			expect(parseSingleRowPipeSeparatedOutput('', 3)).toBeNull();
			expect(parseSingleRowPipeSeparatedOutput('\n', 3)).toBeNull();
		});

		it('throws when the column count disagrees with the contract', () => {
			expect(() => parseSingleRowPipeSeparatedOutput('a|b\n', 3)).toThrow(
				/expected 3 psql columns but got 2/
			);
		});

		it('throws when output contains more than one non-empty row', () => {
			expect(() => parseSingleRowPipeSeparatedOutput('a|b|c\nd|e|f\n', 3)).toThrow(
				/expected single-row.*got 2/i
			);
		});

		it('throws when any column is a NULL marker — fail loud rather than mis-interpret', () => {
			expect(() => parseSingleRowPipeSeparatedOutput('a|\\N|c\n', 3)).toThrow(/null markers/i);
		});

		it('preserves empty-string columns that are NOT NULL markers (Stage 2: presence-flag bool columns)', () => {
			// `email_verified_at IS NULL` renders as 't' or 'f' under psql -tA;
			// but for variable-width payloads (e.g. stripe_customer_id can be
			// NULL → empty string when paired with COALESCE), the parser must
			// not confuse an empty column with a NULL marker.
			const columns = parseSingleRowPipeSeparatedOutput(
				'00000000-0000-0000-0000-000000000001|active||f|t\n',
				5
			);
			expect(columns).toEqual(['00000000-0000-0000-0000-000000000001', 'active', '', 'f', 't']);
		});
	});

	describe('buildCustomerStatusLookupSql (Stage 2 shared seam)', () => {
		it('selects id, status, coalesced stripe_customer_id, and verified-state booleans by email', () => {
			const sql = buildCustomerStatusLookupSql('e2e-fresh-signup-1234@e2e.griddle.test');
			// Schema (infra/migrations/001_customers.sql, 006_auth.sql):
			//   customers(id UUID, status TEXT, stripe_customer_id TEXT NULL,
			//             email_verified_at TIMESTAMPTZ NULL, email_verify_token TEXT NULL).
			// The readback must surface (a) id for ownership chains,
			// (b) status for account-delete / admin-suspend proofs,
			// (c) stripe_customer_id for billing cross-checks (NULL → empty),
			// (d) email_verified_at IS NULL flag for verify-email proofs, and
			// (e) email_verify_token IS NULL flag for consumed-token proofs.
			expect(sql).toContain('id::text');
			expect(sql).toContain('status::text');
			expect(sql).toMatch(/COALESCE\(stripe_customer_id,\s*''\)/i);
			expect(sql).toContain('email_verified_at IS NULL');
			expect(sql).toContain('email_verify_token IS NULL');
			expect(sql).toContain('FROM customers');
			expect(sql).toContain("WHERE email = 'e2e-fresh-signup-1234@e2e.griddle.test'");
		});

		it('rejects emails containing single quotes (SQL injection guard)', () => {
			expect(() => buildCustomerStatusLookupSql("evil'; DROP TABLE customers;--")).toThrow(
				/refusing to embed unsafe email/i
			);
		});

		it('rejects empty email', () => {
			expect(() => buildCustomerStatusLookupSql('')).toThrow(/refusing to embed unsafe email/i);
		});

		it('rejects emails containing whitespace (which would smuggle SQL via line breaks)', () => {
			expect(() => buildCustomerStatusLookupSql('a@b.com\nDROP')).toThrow(
				/refusing to embed unsafe email/i
			);
		});

		it('rejects emails containing backslashes (escape-injection guard)', () => {
			expect(() => buildCustomerStatusLookupSql('back\\slash@b.com')).toThrow(
				/refusing to embed unsafe email/i
			);
		});

		it('keeps the customer-status lookup ownership in staging_db_lookup.ts only', () => {
			const stagingLookupSource = readFileSync(
				join(process.cwd(), 'tests/fixtures/staging_db_lookup.ts'),
				'utf8'
			);
			const fixtureSource = readFileSync(join(process.cwd(), 'tests/fixtures/fixtures.ts'), 'utf8');
			expect(stagingLookupSource).toMatch(/\bbuildCustomerStatusLookupSql\b/);
			expect(stagingLookupSource).toMatch(/\bparseSingleRowPipeSeparatedOutput\b/);
			expect(fixtureSource).not.toMatch(/\bbuildCustomerStatusLookupSql\b/);
			// Per Stage 2 SSOT, no spec/fixture file should inline COALESCE+IS NULL
			// against the customers table — the seam owns the SQL.
			expect(fixtureSource).not.toMatch(/email_verified_at IS NULL/);
			expect(fixtureSource).not.toMatch(/email_verify_token IS NULL/);
		});

		it('exposes the customer-status seam through the shared fixture type surface', () => {
			const fixtureSource = readFileSync(join(process.cwd(), 'tests/fixtures/fixtures.ts'), 'utf8');
			expect(fixtureSource).toMatch(/\bfindCustomerStatusViaStagingSsm\b/);
			expect(fixtureSource).toMatch(
				/type\s+FindCustomerStatusViaStagingSsmFn\s*=\s*\(email:\s*string\)\s*=>\s*Promise<StagingCustomerStatusEvidence>;/
			);
			expect(fixtureSource).toMatch(
				/findCustomerStatusViaStagingSsm:\s*FindCustomerStatusViaStagingSsmFn;/
			);
		});

		it('wires the customer-status seam in base.extend so callers can use the fixture directly', () => {
			const fixtureSource = readFileSync(join(process.cwd(), 'tests/fixtures/fixtures.ts'), 'utf8');
			expect(fixtureSource).toMatch(
				/findCustomerStatusViaStagingSsm:\s*async\s*\(\{\},\s*use\)\s*=>\s*\{[\s\S]*await use\(\(email\)\s*=>\s*findCustomerStatusViaStagingSsm\(email\)\);[\s\S]*\}/
			);
		});
	});
});
