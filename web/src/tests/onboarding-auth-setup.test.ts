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

vi.mock('../../tests/fixtures/staging_db_lookup', async (importOriginal) => {
	const actual = await importOriginal<typeof import('../../tests/fixtures/staging_db_lookup')>();
	return {
		...actual,
		findVerificationTokenViaStagingSsm: vi.fn()
	};
});

import { spawnSync, execFileSync } from 'child_process';
import type { SpawnSyncReturns } from 'child_process';
import { findVerificationTokenViaStagingSsm } from '../../tests/fixtures/staging_db_lookup';
import { REMOTE_TARGET_OPT_IN_ENV } from '../../playwright.config.contract';
import {
	arrangeFreshOnboardingProjectPrerequisites,
	assertSingleVerifiedCustomer,
	verifyFreshSignupEmail
} from '../../tests/fixtures/onboarding-auth-shared';

const mockSpawnSync = vi.mocked(spawnSync);
const mockExecFileSync = vi.mocked(execFileSync);
const mockFindVerificationTokenViaStagingSsm = vi.mocked(findVerificationTokenViaStagingSsm);

describe('onboarding auth setup helpers', () => {
	const originalEnv = process.env;

	beforeEach(() => {
		vi.clearAllMocks();
		process.env = { ...originalEnv };
	});

	afterEach(() => {
		mockSpawnSync.mockReset();
		mockExecFileSync.mockReset();
		mockFindVerificationTokenViaStagingSsm.mockReset();
		vi.unstubAllGlobals();
		vi.useRealTimers();
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

	describe('arrangeFreshOnboardingProjectPrerequisites', () => {
		it('refreshes the selected local region after verifying the setup account', async () => {
			process.env.DATABASE_URL = 'postgres://user:pass@localhost:5432/fjcloud';
			process.env.E2E_TEST_REGION = 'eu-west-1';
			mockSpawnSync.mockReturnValueOnce({
				status: 0,
				stdout: 'already_verified\n',
				stderr: '',
				pid: 1234,
				output: [],
				signal: null,
				error: undefined
			} as unknown as SpawnSyncReturns<string>);
			const ensureLocalSharedVmInventory = vi.fn().mockResolvedValue(undefined);

			await arrangeFreshOnboardingProjectPrerequisites(
				'user@test.com',
				ensureLocalSharedVmInventory
			);

			expect(mockSpawnSync).toHaveBeenCalledOnce();
			expect(ensureLocalSharedVmInventory).toHaveBeenCalledOnce();
			expect(ensureLocalSharedVmInventory).toHaveBeenCalledWith('eu-west-1');
		});
	});

	// -----------------------------------------------------------------------
	// verifyFreshSignupEmail
	// -----------------------------------------------------------------------
	describe('verifyFreshSignupEmail', () => {
		// verifyFreshSignupEmail is async: it must be awaited via
		// `await expect(...).rejects.toThrow(...)` / `.resolves.toBeUndefined()`.
		// Synchronous `expect(() => fn()).toThrow(...)` matchers do not work on
		// async functions — they produce an unhandled rejection per case and
		// the matcher silently passes.

		it('throws when DATABASE_URL is not set', async () => {
			delete process.env.DATABASE_URL;

			await expect(verifyFreshSignupEmail('user@test.com')).rejects.toThrow(
				'DATABASE_URL must be set for onboarding auth setup'
			);
		});

		it('succeeds via host psql when local state needs verification and update count is 1', async () => {
			process.env.DATABASE_URL = 'postgres://user:pass@localhost:5432/fjcloud';

			mockSpawnSync.mockReturnValueOnce({
				status: 0,
				stdout: 'needs_verification\n',
				stderr: '',
				pid: 1234,
				output: [],
				signal: null,
				error: undefined
			} as unknown as SpawnSyncReturns<string>);
			mockSpawnSync.mockReturnValueOnce({
				status: 0,
				stdout: '1\n',
				stderr: '',
				pid: 1234,
				output: [],
				signal: null,
				error: undefined
			} as unknown as SpawnSyncReturns<string>);

			await expect(verifyFreshSignupEmail('user@test.com')).resolves.toBeUndefined();

			// Verify spawnSync was called with psql and the database URL
			expect(mockSpawnSync).toHaveBeenCalledTimes(2);
			const [cmd, args, options] = mockSpawnSync.mock.calls[1];
			expect(cmd).toBe('psql');
			expect(args).not.toContain('postgres://user:pass@localhost:5432/fjcloud');
			expect(args).toEqual(
				expect.arrayContaining(['-h', 'localhost', '-p', '5432', '-U', 'user', '-d', 'fjcloud'])
			);
			expect(args).not.toContain('signup_email=user@test.com');
			expect(options?.env?.PGPASSWORD).toBe('pass');
		});

		it('returns early when local state is already verified', async () => {
			process.env.DATABASE_URL = 'postgres://user:pass@localhost:5432/fjcloud';

			mockSpawnSync.mockReturnValueOnce({
				status: 0,
				stdout: 'already_verified\n',
				stderr: '',
				pid: 1234,
				output: [],
				signal: null,
				error: undefined
			} as unknown as SpawnSyncReturns<string>);

			await expect(verifyFreshSignupEmail('user@test.com')).resolves.toBeUndefined();
			expect(mockSpawnSync).toHaveBeenCalledOnce();
			expect(mockExecFileSync).not.toHaveBeenCalled();
		});

		it('retries staging verify-email on 429 and succeeds on the next response', async () => {
			vi.useFakeTimers();
			process.env[REMOTE_TARGET_OPT_IN_ENV] = '1';
			process.env.API_URL = 'https://api.staging.flapjack.foo';
			mockFindVerificationTokenViaStagingSsm.mockResolvedValue('staging-token-123');
			const fetchMock = vi
				.fn<typeof fetch>()
				.mockResolvedValueOnce(
					new Response('', {
						status: 429,
						headers: { 'retry-after': '0' }
					})
				)
				.mockResolvedValueOnce(new Response('', { status: 200 }));
			vi.stubGlobal('fetch', fetchMock);

			const pending = verifyFreshSignupEmail('user@test.com');
			await vi.runAllTimersAsync();
			await expect(pending).resolves.toBeUndefined();
			expect(mockFindVerificationTokenViaStagingSsm).toHaveBeenCalledWith('user@test.com');
			expect(fetchMock).toHaveBeenCalledTimes(2);
			expect(fetchMock).toHaveBeenNthCalledWith(
				1,
				'https://api.staging.flapjack.foo/auth/verify-email',
				expect.objectContaining({
					method: 'POST',
					body: JSON.stringify({ token: 'staging-token-123' })
				})
			);
		});

		it('surfaces the staging request id when remote verify-email returns a hard failure', async () => {
			process.env[REMOTE_TARGET_OPT_IN_ENV] = '1';
			process.env.API_URL = 'https://api.staging.flapjack.foo';
			mockFindVerificationTokenViaStagingSsm.mockResolvedValue('staging-token-123');
			vi.stubGlobal(
				'fetch',
				vi.fn<typeof fetch>().mockResolvedValue(
					new Response('', {
						status: 503,
						headers: { 'x-request-id': 'req-123' }
					})
				)
			);

			await expect(verifyFreshSignupEmail('user@test.com')).rejects.toThrow(
				/status=503 request_id=req-123/
			);
		});

		it('wraps remote transport failures with the onboarding setup context', async () => {
			process.env[REMOTE_TARGET_OPT_IN_ENV] = '1';
			process.env.API_URL = 'https://api.staging.flapjack.foo';
			mockFindVerificationTokenViaStagingSsm.mockResolvedValue('staging-token-123');
			vi.stubGlobal('fetch', vi.fn<typeof fetch>().mockRejectedValue(new Error('socket hang up')));

			await expect(verifyFreshSignupEmail('user@test.com')).rejects.toThrow(
				/transport_error=socket hang up/
			);
		});

		it('throws when host psql succeeds but updates zero rows', async () => {
			process.env.DATABASE_URL = 'postgres://user:pass@localhost:5432/fjcloud';

			mockSpawnSync.mockReturnValueOnce({
				status: 0,
				stdout: 'needs_verification\n',
				stderr: '',
				pid: 1234,
				output: [],
				signal: null,
				error: undefined
			} as unknown as SpawnSyncReturns<string>);
			mockSpawnSync.mockReturnValueOnce({
				status: 0,
				stdout: '0\n',
				stderr: '',
				pid: 1234,
				output: [],
				signal: null,
				error: undefined
			} as unknown as SpawnSyncReturns<string>);

			await expect(verifyFreshSignupEmail('user@test.com')).rejects.toThrow(
				/did not update exactly one row/
			);
		});

		it('throws when local state lookup returns an unexpected verification state', async () => {
			process.env.DATABASE_URL = 'postgres://user:pass@localhost:5432/fjcloud';

			mockSpawnSync.mockReturnValueOnce({
				status: 0,
				stdout: 'unverified_missing_token\n',
				stderr: '',
				pid: 1234,
				output: [],
				signal: null,
				error: undefined
			} as unknown as SpawnSyncReturns<string>);

			await expect(verifyFreshSignupEmail('user@test.com')).rejects.toThrow(
				/unexpected local customer state/
			);
			expect(mockSpawnSync).toHaveBeenCalledOnce();
		});

		it('falls back to docker compose psql when host psql is ENOENT', async () => {
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

			// Docker compose fallback succeeds for both the state lookup and the update.
			mockExecFileSync.mockReturnValueOnce('needs_verification\n');
			mockExecFileSync.mockReturnValueOnce('1\n');

			await expect(verifyFreshSignupEmail('user@test.com')).resolves.toBeUndefined();

			// Verify docker compose was called with correct DB credentials parsed from URL
			expect(mockExecFileSync).toHaveBeenCalledTimes(2);
			const [dockerCmd, dockerArgs, dockerOptions] = mockExecFileSync.mock.calls[1];
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

		it('throws clear message when psql ENOENT and docker fallback also fails', async () => {
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

			await expect(verifyFreshSignupEmail('user@test.com')).rejects.toThrow(
				/psql is not installed and docker compose fallback also failed/
			);
			await expect(verifyFreshSignupEmail('user@test.com')).rejects.toThrow(
				/install psql.*or.*docker compose exec postgres psql/
			);
		});

		it('throws stderr when host psql fails with non-ENOENT error', async () => {
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

			await expect(verifyFreshSignupEmail('user@test.com')).rejects.toThrow(
				/psql: error: connection to server failed/
			);

			// Should NOT have attempted docker fallback
			expect(mockExecFileSync).not.toHaveBeenCalled();
		});

		it('re-throws non-Error exceptions from host psql directly', async () => {
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

			await expect(verifyFreshSignupEmail('user@test.com')).rejects.toThrow(TypeError);
			await expect(verifyFreshSignupEmail('user@test.com')).rejects.toThrow(
				'unexpected type error in spawn'
			);
		});
	});
});
