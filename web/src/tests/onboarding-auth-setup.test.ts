import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// Mock child_process before importing the module under test.
// The onboarding auth setup uses spawnSync for host psql and execFileSync
// for the docker compose fallback. Must include default export for ESM compat.
vi.mock('child_process', async (importOriginal) => {
	const actual = await importOriginal<typeof import('child_process')>();
	const mocked = {
		...actual,
		spawnSync: vi.fn(),
		execFileSync: vi.fn()
	};
	return { ...mocked, default: mocked };
});

// Mock @playwright/test so the module-level `setup()` call does not throw
// when the module is imported outside of Playwright.
vi.mock('@playwright/test', () => ({
	test: Object.assign(vi.fn(), { extend: vi.fn() }),
	expect: vi.fn()
}));

import { spawnSync, execFileSync } from 'child_process';
import type { SpawnSyncReturns } from 'child_process';
import {
	assertSingleVerifiedCustomer,
	verifyFreshSignupEmail
} from '../../tests/fixtures/onboarding-auth-shared';

const mockSpawnSync = vi.mocked(spawnSync);
const mockExecFileSync = vi.mocked(execFileSync);

describe('onboarding auth setup helpers', () => {
	const originalEnv = process.env;

	beforeEach(() => {
		vi.clearAllMocks();
		process.env = { ...originalEnv };
	});

	afterEach(() => {
		process.env = originalEnv;
	});

	// -----------------------------------------------------------------------
	// assertSingleVerifiedCustomer
	// -----------------------------------------------------------------------
	describe('assertSingleVerifiedCustomer', () => {
		it('accepts output ending with count "1" (single verified row)', () => {
			expect(() =>
				assertSingleVerifiedCustomer('UPDATE 1\n1\n', 'user@test.com', 'host psql')
			).not.toThrow();
		});

		it('accepts output with trailing whitespace around "1"', () => {
			expect(() =>
				assertSingleVerifiedCustomer('UPDATE 1\n  1  \n', 'user@test.com', 'host psql')
			).not.toThrow();
		});

		it('throws when count is "0" (no rows updated)', () => {
			expect(() =>
				assertSingleVerifiedCustomer('UPDATE 0\n0\n', 'user@test.com', 'host psql')
			).toThrow(/did not update exactly one row for user@test\.com/);
		});

		it('throws when output is empty', () => {
			expect(() =>
				assertSingleVerifiedCustomer('', 'user@test.com', 'docker compose psql')
			).toThrow(/did not update exactly one row/);
		});

		it('includes the transport name in the error message', () => {
			expect(() => assertSingleVerifiedCustomer('0\n', 'u@t.com', 'docker compose psql')).toThrow(
				/docker compose psql/
			);
		});
	});

	// -----------------------------------------------------------------------
	// verifyFreshSignupEmail
	// -----------------------------------------------------------------------
	describe('verifyFreshSignupEmail', () => {
		it('throws when DATABASE_URL is not set', () => {
			delete process.env.DATABASE_URL;

			expect(() => verifyFreshSignupEmail('user@test.com')).toThrow(
				'DATABASE_URL must be set for onboarding auth setup'
			);
		});

		it('succeeds via host psql when spawnSync returns status 0 with count 1', () => {
			process.env.DATABASE_URL = 'postgres://user:pass@localhost:5432/fjcloud';

			mockSpawnSync.mockReturnValue({
				status: 0,
				stdout: 'UPDATE 1\n1\n',
				stderr: '',
				pid: 1234,
				output: [],
				signal: null,
				error: undefined
			} as unknown as SpawnSyncReturns<string>);

			expect(() => verifyFreshSignupEmail('user@test.com')).not.toThrow();

			// Verify spawnSync was called with psql and the database URL
			expect(mockSpawnSync).toHaveBeenCalledOnce();
			const [cmd, args, options] = mockSpawnSync.mock.calls[0];
			expect(cmd).toBe('psql');
			expect(args).not.toContain('postgres://user:pass@localhost:5432/fjcloud');
			expect(args).toEqual(
				expect.arrayContaining(['-h', 'localhost', '-p', '5432', '-U', 'user', '-d', 'fjcloud'])
			);
			expect(args).not.toContain('signup_email=user@test.com');
			expect(options?.env?.PGPASSWORD).toBe('pass');
		});

		it('throws when host psql succeeds but updates zero rows', () => {
			process.env.DATABASE_URL = 'postgres://user:pass@localhost:5432/fjcloud';

			mockSpawnSync.mockReturnValue({
				status: 0,
				stdout: 'UPDATE 0\n0\n',
				stderr: '',
				pid: 1234,
				output: [],
				signal: null,
				error: undefined
			} as unknown as SpawnSyncReturns<string>);

			expect(() => verifyFreshSignupEmail('user@test.com')).toThrow(
				/did not update exactly one row/
			);
		});

		it('falls back to docker compose psql when host psql is ENOENT', () => {
			process.env.DATABASE_URL = 'postgres://testuser:testpass@localhost:5432/fjcloud_test';

			// Host psql not found — ENOENT
			const enoentError = new Error('spawnSync psql ENOENT');
			mockSpawnSync.mockReturnValue({
				status: null,
				stdout: '',
				stderr: '',
				pid: 0,
				output: [],
				signal: null,
				error: enoentError
			} as unknown as SpawnSyncReturns<string>);

			// Docker compose fallback succeeds
			mockExecFileSync.mockReturnValue('UPDATE 1\n1\n');

			expect(() => verifyFreshSignupEmail('user@test.com')).not.toThrow();

			// Verify docker compose was called with correct DB credentials parsed from URL
			expect(mockExecFileSync).toHaveBeenCalledOnce();
			const [dockerCmd, dockerArgs, dockerOptions] = mockExecFileSync.mock.calls[0];
			expect(dockerCmd).toBe('docker');
			expect(dockerArgs).toContain('compose');
			expect(dockerArgs).toEqual(
				expect.arrayContaining([
					'exec',
					'-T',
					'-e',
					'PGPASSWORD',
					'-e',
					'PSQLRC',
					'postgres',
					'psql',
					'-U',
					'testuser',
					'-d',
					'fjcloud_test'
				])
			);
			expect(dockerArgs).not.toContain('-h');
			expect(dockerArgs).not.toContain('-p');
			expect(dockerArgs).not.toContain('signup_email=user@test.com');
			expect(dockerArgs).not.toContain('PGPASSWORD=testpass');
			expect(dockerOptions?.env?.PGPASSWORD).toBe('testpass');
		});

		it('throws clear message when psql ENOENT and docker fallback also fails', () => {
			process.env.DATABASE_URL = 'postgres://user:pass@localhost:5432/fjcloud';

			// Host psql not found
			const enoentError = new Error('spawnSync psql ENOENT');
			mockSpawnSync.mockReturnValue({
				status: null,
				stdout: '',
				stderr: '',
				pid: 0,
				output: [],
				signal: null,
				error: enoentError
			} as unknown as SpawnSyncReturns<string>);

			// Docker also fails
			mockExecFileSync.mockImplementation(() => {
				throw new Error('docker compose exec failed: container not running');
			});

			expect(() => verifyFreshSignupEmail('user@test.com')).toThrow(
				/psql is not installed and docker compose fallback also failed/
			);
			expect(() => verifyFreshSignupEmail('user@test.com')).toThrow(
				/install psql.*or.*docker compose exec postgres psql/
			);
		});

		it('throws stderr when host psql fails with non-ENOENT error', () => {
			process.env.DATABASE_URL = 'postgres://user:pass@localhost:5432/fjcloud';

			// psql found but connection refused
			mockSpawnSync.mockReturnValue({
				status: 2,
				stdout: '',
				stderr: 'psql: error: connection to server failed',
				pid: 1234,
				output: [],
				signal: null,
				error: undefined
			} as unknown as SpawnSyncReturns<string>);

			expect(() => verifyFreshSignupEmail('user@test.com')).toThrow(
				/psql: error: connection to server failed/
			);

			// Should NOT have attempted docker fallback
			expect(mockExecFileSync).not.toHaveBeenCalled();
		});

		it('re-throws non-Error exceptions from host psql directly', () => {
			process.env.DATABASE_URL = 'postgres://user:pass@localhost:5432/fjcloud';

			// Unusual error type (e.g. SystemError)
			const weirdError = new TypeError('unexpected type error in spawn');
			mockSpawnSync.mockReturnValue({
				status: null,
				stdout: '',
				stderr: '',
				pid: 0,
				output: [],
				signal: null,
				error: weirdError
			} as unknown as SpawnSyncReturns<string>);

			expect(() => verifyFreshSignupEmail('user@test.com')).toThrow(TypeError);
			expect(() => verifyFreshSignupEmail('user@test.com')).toThrow(
				'unexpected type error in spawn'
			);
		});
	});
});
