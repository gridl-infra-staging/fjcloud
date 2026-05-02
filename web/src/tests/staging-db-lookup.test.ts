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
	buildSsmStagingPsqlCommand,
	buildVerificationTokenLookupSql,
	parseSingleColumnSingleRowOutput
} from '../../tests/fixtures/staging_db_lookup';

describe('staging DB lookup helper (LB-2/LB-3)', () => {
	it('keeps fallback DB lookup ownership in staging_db_lookup.ts only', () => {
		const stagingLookupSource = readFileSync(
			join(process.cwd(), 'tests/fixtures/staging_db_lookup.ts'),
			'utf8'
		);
		const fixtureSource = readFileSync(join(process.cwd(), 'tests/fixtures/fixtures.ts'), 'utf8');

		expect(stagingLookupSource).toMatch(/\bbuildVerificationTokenLookupSql\b/);
		expect(stagingLookupSource).toMatch(/\bbuildSsmStagingPsqlCommand\b/);
		expect(stagingLookupSource).toMatch(/\bexecSsmStagingShell\b/);
		expect(fixtureSource).not.toMatch(/\bbuildVerificationTokenLookupSql\b/);
		expect(fixtureSource).not.toMatch(/\bbuildSsmStagingPsqlCommand\b/);
		expect(fixtureSource).not.toMatch(/\bexecSsmStagingShell\b/);
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
});
