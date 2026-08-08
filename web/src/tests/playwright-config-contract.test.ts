import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { describe, expect, it, vi } from 'vitest';
import { deriveApiBaseUrl } from '../lib/config';
import {
	applyPlaywrightProcessEnvDefaults,
	DEFAULT_API_URL,
	DEFAULT_E2E_USER_EMAIL,
	DEFAULT_E2E_USER_PASSWORD,
	DEFAULT_FLAPJACK_URL,
	DEFAULT_PLAYWRIGHT_ADMIN_KEY,
	DEFAULT_TEST_REGION,
	PLAYWRIGHT_STORAGE_STATE,
	PLAYWRIGHT_PROJECT_CONTRACTS,
	PLAYWRIGHT_API_PORT_ENV,
	PLAYWRIGHT_FLAPJACK_PORT_ENV,
	PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION_ENV,
	PLAYWRIGHT_WEB_PORT_ENV,
	PLAYWRIGHT_PROVIDER_PARITY_SHUTDOWN_TIMEOUT_MS,
	PLAYWRIGHT_WEB_SERVER_COMMAND,
	PLAYWRIGHT_WEB_ONLY_SERVER_COMMAND,
	PLAYWRIGHT_WEB_SERVER_TIMEOUT_MS,
	parseDotenvFile,
	parseDotenvValue,
	resolveDefaultPlaywrightWebPort,
	resolveDefaultPlaywrightApiPort,
	resolveDefaultPlaywrightFlapjackPort,
	resolveDefaultPlaywrightLocalDbPort,
	resolveDefaultPlaywrightMeilisearchPort,
	resolveDefaultPlaywrightTypesensePort,
	REMOTE_TARGET_OPT_IN_ENV,
	REMOTE_TARGET_HOST_SUFFIX_ALLOWLIST,
	requireLoopbackHttpUrl,
	resolveFixtureEnv,
	resolveRequiredFixtureAdminKey,
	resolveRequiredFixtureUserCredentials,
	resolvePlaywrightRuntime,
	sanitizeWebServerEnv,
	selectPlaywrightSecretEnv,
	type PlaywrightWebServerContract
} from '../../playwright.config.contract';
import { formatFixtureSetupFailure } from '../../tests/fixtures/setup_failure_message';

type MutableEnv = Record<string, string | undefined>;
type LoadedEnv = Record<string, string>;
type EnvDefaultsInput = {
	processEnv: MutableEnv;
	repoEnv: LoadedEnv;
	webEnv: LoadedEnv;
};

const projectContractsByName = Object.fromEntries(
	PLAYWRIGHT_PROJECT_CONTRACTS.map((project) => [project.name, project])
);
const EMAIL_VERIFICATION_PROJECT_NAME = 'chromium:email-verification';

function applyEnvDefaults(input: EnvDefaultsInput): MutableEnv {
	applyPlaywrightProcessEnvDefaults(input);
	return input.processEnv;
}

function withProcessEnv<T>(overrides: Record<string, string | undefined>, run: () => T): T {
	const previousEntries = Object.entries(overrides).map(
		([key]) => [key, process.env[key]] as const
	);

	for (const [key, value] of Object.entries(overrides)) {
		if (value === undefined) {
			delete process.env[key];
			continue;
		}
		process.env[key] = value;
	}

	try {
		return run();
	} finally {
		for (const [key, value] of previousEntries) {
			if (value === undefined) {
				delete process.env[key];
				continue;
			}
			process.env[key] = value;
		}
	}
}

function expectLocalAutoVerificationBypass(env: Record<string, string | undefined>): void {
	expect(env.ENVIRONMENT).toBe('local');
	expect(env.SKIP_EMAIL_VERIFICATION).toBe('1');
	expect(env.API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION).toBe('1');
	expect(env[PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION_ENV]).toBeUndefined();
}

function expectRequiredEmailVerification(env: Record<string, string | undefined>): void {
	expect(env.ENVIRONMENT).toBe('local');
	expect(env[PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION_ENV]).toBe('1');
	expect(env.SKIP_EMAIL_VERIFICATION).toBeUndefined();
	expect(env.API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION).toBeUndefined();
}

async function withIsolatedProcessEnv<T>(
	overrides: Record<string, string | undefined>,
	run: () => Promise<T>
): Promise<T> {
	const previousEnv = { ...process.env };

	for (const key of Object.keys(process.env)) {
		delete process.env[key];
	}
	for (const [key, value] of Object.entries(overrides)) {
		if (value !== undefined) {
			process.env[key] = value;
		}
	}

	try {
		return await run();
	} finally {
		for (const key of Object.keys(process.env)) {
			delete process.env[key];
		}
		for (const [key, value] of Object.entries(previousEnv)) {
			process.env[key] = value;
		}
	}
}

describe('playwright config contract', () => {
	it('allows stack bootstrap work before the full API readiness budget', () => {
		expect(PLAYWRIGHT_WEB_SERVER_TIMEOUT_MS).toBe(600_000);
	});

	it('parseDotenvValue handles quoted, escaped, and commented values', () => {
		expect(parseDotenvValue('"line1\\nline2"')).toBe('line1\nline2');
		expect(parseDotenvValue("'single quoted value'")).toBe('single quoted value');
		expect(parseDotenvValue('plain-value # trailing comment')).toBe('plain-value');
	});

	it('parseDotenvFile supports export syntax and ignores invalid keys', () => {
		const tmpPath = mkdtempSync(join(tmpdir(), 'playwright-contract-'));
		const envFilePath = join(tmpPath, '.env.local');
		writeFileSync(
			envFilePath,
			[
				'# comment',
				'export API_URL=http://localhost:3001',
				'BASE_URL=http://127.0.0.1:4174',
				'INVALID-KEY=ignored',
				'JWT_SECRET="quoted-secret"'
			].join('\n')
		);

		try {
			expect(parseDotenvFile(envFilePath)).toEqual({
				API_URL: 'http://localhost:3001',
				BASE_URL: 'http://127.0.0.1:4174',
				JWT_SECRET: 'quoted-secret'
			});
		} finally {
			rmSync(tmpPath, { recursive: true, force: true });
		}
	});

	it('sanitizeWebServerEnv removes undefined entries', () => {
		expect(
			sanitizeWebServerEnv({
				API_URL: 'http://localhost:3001',
				BASE_URL: undefined
			})
		).toEqual({
			API_URL: 'http://localhost:3001'
		});
	});

	it('deriveApiBaseUrl only rewrites known cloud custom domains', () => {
		expect(deriveApiBaseUrl('cloud.flapjack.foo')).toBe('https://api.flapjack.foo');
		expect(deriveApiBaseUrl('cloud.staging.flapjack.foo')).toBe('https://api.staging.flapjack.foo');
	});

	it('deriveApiBaseUrl falls back instead of trusting arbitrary cloud-prefixed hosts', () => {
		withProcessEnv(
			{
				API_BASE_URL: '',
				API_URL: '',
				ENVIRONMENT: '',
				PLAYWRIGHT_API_PORT: '3999'
			},
			() => {
				const expectedFallback = deriveApiBaseUrl('unrecognized-host.example');
				expect(deriveApiBaseUrl('cloud.flapjack.foo.evil.com')).toBe(expectedFallback);
				expect(deriveApiBaseUrl('cloud.attacker.example')).toBe(expectedFallback);
			}
		);
	});

	it('applyPlaywrightProcessEnvDefaults seeds runner env from .env values and seed defaults', () => {
		const processEnv = applyEnvDefaults({
			processEnv: {},
			repoEnv: {
				SEED_USER_EMAIL: 'repo-seed@example.com',
				DATABASE_URL: 'postgres://repo-user:repo-pass@localhost:5432/fjcloud'
			},
			webEnv: {
				E2E_ADMIN_KEY: 'web-e2e-admin',
				E2E_USER_EMAIL: 'web-e2e@example.com',
				E2E_USER_PASSWORD: 'web-e2e-password'
			}
		});

		expect(processEnv.E2E_ADMIN_KEY).toBe('web-e2e-admin');
		expect(processEnv.E2E_USER_EMAIL).toBe('web-e2e@example.com');
		expect(processEnv.E2E_USER_PASSWORD).toBe('web-e2e-password');
		expect(processEnv.DATABASE_URL).toBe('postgres://repo-user:repo-pass@localhost:5432/fjcloud');
	});

	it('applyPlaywrightProcessEnvDefaults falls back from ADMIN_KEY and seed env when direct E2E_* vars are absent', () => {
		const processEnv = applyEnvDefaults({
			processEnv: {},
			repoEnv: {
				ADMIN_KEY: 'repo-admin',
				SEED_USER_EMAIL: 'repo-seed@example.com',
				DATABASE_URL: 'postgres://repo-user:repo-pass@localhost:5432/fjcloud'
			},
			webEnv: {
				SEED_USER_PASSWORD: 'web-seed-password'
			}
		});

		expect(processEnv.E2E_ADMIN_KEY).toBe('repo-admin');
		expect(processEnv.E2E_USER_EMAIL).toBe('repo-seed@example.com');
		expect(processEnv.E2E_USER_PASSWORD).toBe('web-seed-password');
		expect(processEnv.DATABASE_URL).toBe('postgres://repo-user:repo-pass@localhost:5432/fjcloud');
	});

	it('applyPlaywrightProcessEnvDefaults preserves explicit E2E overrides and uses documented defaults', () => {
		const processEnv = applyEnvDefaults({
			processEnv: {
				E2E_ADMIN_KEY: 'explicit-admin',
				E2E_USER_EMAIL: 'explicit@example.com',
				E2E_USER_PASSWORD: 'explicit-password',
				DATABASE_URL: 'postgres://explicit-user:explicit-pass@localhost:5432/fjcloud'
			},
			repoEnv: {
				ADMIN_KEY: 'repo-admin'
			},
			webEnv: {}
		});

		expect(processEnv.E2E_ADMIN_KEY).toBe('explicit-admin');
		expect(processEnv.E2E_USER_EMAIL).toBe('explicit@example.com');
		expect(processEnv.E2E_USER_PASSWORD).toBe('explicit-password');
		expect(processEnv.DATABASE_URL).toBe(
			'postgres://explicit-user:explicit-pass@localhost:5432/fjcloud'
		);

		const defaultedEnv = applyEnvDefaults({
			processEnv: {},
			repoEnv: {},
			webEnv: {}
		});
		expect(defaultedEnv.E2E_USER_EMAIL).toBe(DEFAULT_E2E_USER_EMAIL);
		expect(defaultedEnv.E2E_USER_PASSWORD).toBe(DEFAULT_E2E_USER_PASSWORD);
		expect(defaultedEnv.E2E_ADMIN_KEY).toBe(DEFAULT_PLAYWRIGHT_ADMIN_KEY);
		expect(defaultedEnv.DATABASE_URL).toBeUndefined();
	});

	it('applyPlaywrightProcessEnvDefaults refuses hardcoded credential fallbacks in remote-target mode', () => {
		const processEnv = applyEnvDefaults({
			processEnv: {
				[REMOTE_TARGET_OPT_IN_ENV]: '1'
			},
			repoEnv: {},
			webEnv: {}
		});

		expect(processEnv.E2E_USER_EMAIL).toBeUndefined();
		expect(processEnv.E2E_USER_PASSWORD).toBeUndefined();
		expect(processEnv.E2E_ADMIN_KEY).toBeUndefined();
	});

	it('applyPlaywrightProcessEnvDefaults refuses ADMIN_KEY fallback for E2E_ADMIN_KEY in remote-target mode', () => {
		const processEnv = applyEnvDefaults({
			processEnv: {
				[REMOTE_TARGET_OPT_IN_ENV]: '1',
				ADMIN_KEY: 'process-admin'
			},
			repoEnv: {
				ADMIN_KEY: 'repo-admin'
			},
			webEnv: {
				ADMIN_KEY: 'web-admin'
			}
		});

		// In remote-target mode, only an explicit E2E_ADMIN_KEY may hydrate the
		// fixture admin-key source. Repo/web/process ADMIN_KEY values must not
		// silently satisfy the staging-only precondition; the cold-customer
		// Algolia-refugee journey contract relies on this fail-closed behavior.
		expect(processEnv.E2E_ADMIN_KEY).toBeUndefined();
	});

	it('applyPlaywrightProcessEnvDefaults keeps local admin fallback for remote-flagged local API runs', () => {
		const processEnv = applyEnvDefaults({
			processEnv: {
				[REMOTE_TARGET_OPT_IN_ENV]: '1'
			},
			repoEnv: {
				API_BASE_URL: 'http://127.0.0.1:3001',
				ADMIN_KEY: 'repo-local-admin'
			},
			webEnv: {}
		});

		expect(processEnv.E2E_ADMIN_KEY).toBe('repo-local-admin');
	});

	it('applyPlaywrightProcessEnvDefaults refuses dotenv-backed E2E_ADMIN_KEY in remote-target mode', () => {
		const processEnv = applyEnvDefaults({
			processEnv: {
				[REMOTE_TARGET_OPT_IN_ENV]: '1'
			},
			repoEnv: {
				E2E_ADMIN_KEY: 'repo-dotenv-key'
			},
			webEnv: {
				E2E_ADMIN_KEY: 'web-dotenv-key'
			}
		});

		// Remote-target mode must only accept shell-exported E2E_ADMIN_KEY
		// (processEnv), not dotenv-backed values from webEnv/repoEnv files.
		expect(processEnv.E2E_ADMIN_KEY).toBeUndefined();
	});

	it('applyPlaywrightProcessEnvDefaults still honors explicit E2E_ADMIN_KEY in remote-target mode', () => {
		const processEnv = applyEnvDefaults({
			processEnv: {
				[REMOTE_TARGET_OPT_IN_ENV]: '1',
				E2E_ADMIN_KEY: 'explicit-staging-admin',
				ADMIN_KEY: 'process-admin'
			},
			repoEnv: {},
			webEnv: {}
		});

		expect(processEnv.E2E_ADMIN_KEY).toBe('explicit-staging-admin');
	});

	it('applyPlaywrightProcessEnvDefaults propagates Mailpit and Stripe env for fixture-owned billing lanes', () => {
		const processEnv = applyEnvDefaults({
			processEnv: {},
			repoEnv: {
				MAILPIT_API_URL: 'http://localhost:8025',
				STRIPE_WEBHOOK_SECRET: 'whsec_repo',
				STRIPE_SECRET_KEY: 'rk_repo'
			},
			webEnv: {
				STRIPE_WEBHOOK_SECRET: 'whsec_web',
				STRIPE_SECRET_KEY: 'rk_web'
			}
		});

		expect(processEnv.MAILPIT_API_URL).toBe('http://localhost:8025');
		expect(processEnv.STRIPE_WEBHOOK_SECRET).toBe('whsec_web');
		expect(processEnv.STRIPE_SECRET_KEY).toBe('rk_web');
	});

	it('applyPlaywrightProcessEnvDefaults maps STRIPE_TEST_SECRET_KEY into worker STRIPE_SECRET_KEY', () => {
		const processEnv = applyEnvDefaults({
			processEnv: {},
			repoEnv: {
				STRIPE_TEST_SECRET_KEY: 'rk_test_repo'
			},
			webEnv: {}
		});

		expect(processEnv.STRIPE_SECRET_KEY).toBe('rk_test_repo');
	});

	it('selectPlaywrightSecretEnv only exposes Stripe keys from the secret file', () => {
		expect(
			selectPlaywrightSecretEnv({
				API_URL: 'https://api.flapjack.foo',
				ADMIN_KEY: 'remote-admin',
				STRIPE_SECRET_KEY: 'rk_test_secret',
				STRIPE_TEST_SECRET_KEY: 'rk_test_alias',
				STRIPE_WEBHOOK_SECRET: 'whsec_secret'
			})
		).toEqual({
			STRIPE_SECRET_KEY: 'rk_test_secret',
			STRIPE_TEST_SECRET_KEY: 'rk_test_alias',
			STRIPE_WEBHOOK_SECRET: 'whsec_secret'
		});
	});

	it('applyPlaywrightProcessEnvDefaults preserves explicit shell overrides for Mailpit and Stripe env', () => {
		const processEnv = applyEnvDefaults({
			processEnv: {
				MAILPIT_API_URL: 'http://127.0.0.1:18025',
				STRIPE_WEBHOOK_SECRET: 'whsec_process',
				STRIPE_SECRET_KEY: 'rk_process'
			},
			repoEnv: {
				MAILPIT_API_URL: 'http://localhost:8025',
				STRIPE_WEBHOOK_SECRET: 'whsec_repo',
				STRIPE_SECRET_KEY: 'rk_repo'
			},
			webEnv: {
				MAILPIT_API_URL: 'http://localhost:28025',
				STRIPE_WEBHOOK_SECRET: 'whsec_web',
				STRIPE_SECRET_KEY: 'rk_web'
			}
		});

		expect(processEnv.MAILPIT_API_URL).toBe('http://127.0.0.1:18025');
		expect(processEnv.STRIPE_WEBHOOK_SECRET).toBe('whsec_process');
		expect(processEnv.STRIPE_SECRET_KEY).toBe('rk_process');
	});

	it('resolvePlaywrightRuntime disables webServer when BASE_URL is overridden to local rerun URL', () => {
		const runtime = resolvePlaywrightRuntime({
			processEnv: {
				BASE_URL: 'http://127.0.0.1:4174',
				E2E_ADMIN_KEY: 'e2e-key'
			},
			repoEnv: { ADMIN_KEY: 'repo-key' },
			webEnv: { ADMIN_KEY: 'web-key' },
			fallbackJwtSecret: 'fallback-jwt'
		});

		expect(runtime.baseURL).toBe('http://127.0.0.1:4174');
		expect(runtime.webServer).toBeUndefined();
		expect(runtime.webServerEnv.ADMIN_KEY).toBe('e2e-key');
		expect(runtime.webServerEnv.FJCLOUD_ALLOW_LOOPBACK_SOURCE_ORIGINS).toBeUndefined();
	});

	it('resolvePlaywrightRuntime starts a web-only server for local BASE_URL no-deps reruns', () => {
		const runtime = resolvePlaywrightRuntime({
			processEnv: {
				BASE_URL: 'http://127.0.0.1:5285',
				E2E_ADMIN_KEY: 'e2e-key'
			},
			repoEnv: {},
			webEnv: {},
			fallbackJwtSecret: 'fallback-jwt',
			argv: [
				'test',
				'tests/e2e-ui/full/oauth_round_trip.spec.ts',
				'--grep',
				'oauth unavailable',
				'--no-deps'
			]
		});

		expect(runtime.baseURL).toBe('http://127.0.0.1:5285');
		expect(runtime.webServer).toEqual({
			command: `${PLAYWRIGHT_WEB_ONLY_SERVER_COMMAND} --host 127.0.0.1 --port 5285 --strictPort`,
			env: runtime.webServerEnv,
			url: 'http://127.0.0.1:5285',
			reuseExistingServer: false,
			timeout: PLAYWRIGHT_WEB_SERVER_TIMEOUT_MS
		});
		expect(runtime.webServerEnv.FJCLOUD_ALLOW_LOOPBACK_SOURCE_ORIGINS).toBe('1');
	});

	it('resolvePlaywrightRuntime rejects non-loopback BASE_URL overrides', () => {
		expect(() =>
			resolvePlaywrightRuntime({
				processEnv: { BASE_URL: 'https://staging.example.com' },
				repoEnv: {},
				webEnv: {},
				fallbackJwtSecret: 'fallback-jwt'
			})
		).toThrow(
			'BASE_URL must use a local loopback host (localhost, 127.0.0.1, or [::1]) for credentialed local browser runs'
		);
	});

	it('resolvePlaywrightRuntime rejects non-loopback API_BASE_URL overrides from explicit process env', () => {
		expect(() =>
			resolvePlaywrightRuntime({
				processEnv: { API_BASE_URL: 'https://api.example.com' },
				repoEnv: {},
				webEnv: {},
				fallbackJwtSecret: 'fallback-jwt'
			})
		).toThrow(
			'API_BASE_URL must use a local loopback host (localhost, 127.0.0.1, or [::1]) for credentialed local browser runs'
		);
	});

	it('resolvePlaywrightRuntime prefers explicit process API_BASE_URL overrides for local reruns', () => {
		const runtime = resolvePlaywrightRuntime({
			processEnv: { API_BASE_URL: 'http://127.0.0.1:4100' },
			repoEnv: { API_BASE_URL: 'http://127.0.0.1:4200' },
			webEnv: { API_BASE_URL: 'http://127.0.0.1:4300' },
			fallbackJwtSecret: 'fallback-jwt'
		});

		expect(runtime.webServerEnv.API_BASE_URL).toBe('http://127.0.0.1:4100');
	});

	it('resolvePlaywrightRuntime preserves an explicit process API_URL override for worker-side helpers', () => {
		const processEnv: MutableEnv = {
			API_BASE_URL: 'http://127.0.0.1:4100',
			API_URL: 'http://127.0.0.1:4101'
		};
		const runtime = resolvePlaywrightRuntime({
			processEnv,
			repoEnv: {
				API_BASE_URL: 'http://127.0.0.1:4200',
				API_URL: 'http://127.0.0.1:4201'
			},
			webEnv: {
				API_BASE_URL: 'http://127.0.0.1:4300',
				API_URL: 'http://127.0.0.1:4301'
			},
			fallbackJwtSecret: 'fallback-jwt'
		});

		expect(runtime.webServerEnv.API_BASE_URL).toBe('http://127.0.0.1:4100');
		expect(runtime.webServerEnv.API_URL).toBe('http://127.0.0.1:4101');
		expect(processEnv.API_BASE_URL).toBe('http://127.0.0.1:4100');
		expect(processEnv.API_URL).toBe('http://127.0.0.1:4101');
	});

	it('resolvePlaywrightRuntime replaces file-backed API endpoints for spawned local stacks', () => {
		const workspacePath = '/tmp/fjcloud-worktree-file-backed-api-endpoints';
		const expectedApiPort = resolveDefaultPlaywrightApiPort(workspacePath);
		const expectedApiBaseUrl = `http://127.0.0.1:${expectedApiPort}`;
		const processEnv: MutableEnv = {
			API_BASE_URL: 'http://127.0.0.1:3001',
			API_URL: 'http://127.0.0.1:3001'
		};
		const repoEnv = {
			API_BASE_URL: 'http://127.0.0.1:3001',
			API_URL: 'http://127.0.0.1:3001'
		};
		const runtime = resolvePlaywrightRuntime({
			processEnv,
			repoEnv,
			webEnv: {},
			fallbackJwtSecret: 'fallback-jwt',
			workspacePath
		});

		expect(runtime.webServerEnv.API_BASE_URL).toBe(expectedApiBaseUrl);
		expect(runtime.webServerEnv.API_URL).toBe(expectedApiBaseUrl);
		expect(processEnv.API_BASE_URL).toBe(expectedApiBaseUrl);
		expect(processEnv.API_URL).toBe(expectedApiBaseUrl);
	});

	// scripts/lib/playwright_port_plan.sh derives LOCAL_DB_PORT as
	// `flapjack + (4 * PLAYWRIGHT_DEFAULT_PORT_HASH_SPAN)`. Pinning the offset to a
	// literal here rather than re-calling the resolver means a change to either
	// runtime's band arithmetic fails this test instead of silently agreeing.
	it('resolveDefaultPlaywrightLocalDbPort sits four spans above the flapjack band', () => {
		const workspacePath = '/tmp/fjcloud-worktree-local-db-band';
		const localDbPort = resolveDefaultPlaywrightLocalDbPort(workspacePath);

		expect(localDbPort - resolveDefaultPlaywrightFlapjackPort(workspacePath)).toBe(8000);
		expect(localDbPort).toBeGreaterThanOrEqual(17700);
		expect(localDbPort).toBeLessThanOrEqual(19699);
		// The database band must not overlap any other service the stack binds for
		// the same workspace, or a provider-parity run collides with itself.
		expect(
			new Set([
				localDbPort,
				resolveDefaultPlaywrightWebPort(workspacePath),
				resolveDefaultPlaywrightApiPort(workspacePath),
				resolveDefaultPlaywrightFlapjackPort(workspacePath),
				resolveDefaultPlaywrightMeilisearchPort(workspacePath),
				resolveDefaultPlaywrightTypesensePort(workspacePath)
			]).size
		).toBe(6);
	});

	it('resolvePlaywrightRuntime rejects a malformed file-backed DATABASE_URL by name', () => {
		const malformedDatabaseUrl = 'not-a-database-url';

		expect(() =>
			resolvePlaywrightRuntime({
				processEnv: { DATABASE_URL: malformedDatabaseUrl },
				repoEnv: { DATABASE_URL: malformedDatabaseUrl },
				webEnv: {},
				fallbackJwtSecret: 'fallback-jwt',
				workspacePath: '/tmp/fjcloud-worktree-malformed-database-url'
			})
		).toThrow('DATABASE_URL must be a valid PostgreSQL URL for local Playwright runs');
	});

	it('resolvePlaywrightRuntime rejects a file-backed non-PostgreSQL DATABASE_URL by name', () => {
		const mysqlDatabaseUrl = 'mysql://repo-user:repo-pass@127.0.0.1:3306/fjcloud';

		expect(() =>
			resolvePlaywrightRuntime({
				processEnv: { DATABASE_URL: mysqlDatabaseUrl },
				repoEnv: { DATABASE_URL: mysqlDatabaseUrl },
				webEnv: {},
				fallbackJwtSecret: 'fallback-jwt',
				workspacePath: '/tmp/fjcloud-worktree-non-postgres-database-url'
			})
		).toThrow('DATABASE_URL must be a valid PostgreSQL URL for local Playwright runs');
	});

	// Rewriting only the port of a remote DATABASE_URL would hand the operator's
	// database credentials to a workspace-derived port on a host nobody pointed
	// them at. The stack's own non-loopback refusal is skipped when an API is
	// already healthy, and runFixtureSql applies no loopback check, so the config
	// has to be the gate. Goes red if the loopback guard is dropped: the rewrite
	// would return a 17700-19699 port on db.internal.example.com instead.
	it('resolvePlaywrightRuntime refuses to rewrite a non-loopback file-backed DATABASE_URL', () => {
		const remoteDatabaseUrl = 'postgres://repo-user:repo-pass@db.internal.example.com:5432/fjcloud';
		const processEnv: MutableEnv = { DATABASE_URL: remoteDatabaseUrl };

		expect(() =>
			resolvePlaywrightRuntime({
				processEnv,
				repoEnv: { DATABASE_URL: remoteDatabaseUrl },
				webEnv: {},
				fallbackJwtSecret: 'fallback-jwt',
				workspacePath: '/tmp/fjcloud-worktree-remote-database-url'
			})
		).toThrow('DATABASE_URL must be a loopback PostgreSQL URL for local Playwright runs');
		// The refusal must not leave a half-rewritten remote URL behind for a
		// caller that swallows the throw.
		expect(processEnv.DATABASE_URL).toBe(remoteDatabaseUrl);
	});

	it('resolvePlaywrightRuntime rewrites loopback DATABASE_URL hosts the stack guards accept', () => {
		for (const host of ['localhost', '127.0.0.1', '127.1.2.3', '[::1]']) {
			const workspacePath = `/tmp/fjcloud-worktree-loopback-${host.replace(/[^a-z0-9]/gi, '-')}`;
			const databaseUrl = `postgres://repo-user:repo-pass@${host}:5432/fjcloud`;
			const processEnv: MutableEnv = { DATABASE_URL: databaseUrl };

			resolvePlaywrightRuntime({
				processEnv,
				repoEnv: { DATABASE_URL: databaseUrl },
				webEnv: {},
				fallbackJwtSecret: 'fallback-jwt',
				workspacePath
			});

			expect(processEnv.DATABASE_URL).toBe(
				`postgres://repo-user:repo-pass@${host}:${resolveDefaultPlaywrightLocalDbPort(workspacePath)}/fjcloud`
			);
		}
	});

	it('resolvePlaywrightRuntime replaces file-backed DATABASE_URL for spawned local stacks', () => {
		const workspacePath = '/tmp/fjcloud-worktree-file-backed-database-url';
		const expectedDatabaseUrl = `postgres://repo-user:repo-pass@127.0.0.1:${resolveDefaultPlaywrightLocalDbPort(workspacePath)}/fjcloud`;
		const processEnv: MutableEnv = {
			DATABASE_URL: 'postgres://repo-user:repo-pass@127.0.0.1:5432/fjcloud'
		};
		const repoEnv = {
			DATABASE_URL: 'postgres://repo-user:repo-pass@127.0.0.1:5432/fjcloud'
		};
		const runtime = resolvePlaywrightRuntime({
			processEnv,
			repoEnv,
			webEnv: {},
			fallbackJwtSecret: 'fallback-jwt',
			workspacePath
		});

		expect(runtime.webServerEnv.DATABASE_URL).toBe(expectedDatabaseUrl);
		expect(processEnv.DATABASE_URL).toBe(expectedDatabaseUrl);
	});

	it('resolvePlaywrightRuntime preserves explicit process DATABASE_URL overrides', () => {
		const processEnv: MutableEnv = {
			DATABASE_URL: 'postgres://explicit-user:explicit-pass@127.0.0.1:15432/fjcloud'
		};
		const runtime = resolvePlaywrightRuntime({
			processEnv,
			repoEnv: {
				DATABASE_URL: 'postgres://repo-user:repo-pass@127.0.0.1:5432/fjcloud'
			},
			webEnv: {},
			fallbackJwtSecret: 'fallback-jwt',
			workspacePath: '/tmp/fjcloud-worktree-explicit-database-url'
		});

		expect(runtime.webServerEnv.DATABASE_URL).toBe(
			'postgres://explicit-user:explicit-pass@127.0.0.1:15432/fjcloud'
		);
		expect(processEnv.DATABASE_URL).toBe(
			'postgres://explicit-user:explicit-pass@127.0.0.1:15432/fjcloud'
		);
	});

	it('resolvePlaywrightRuntime uses default base URL and admin fallback chain without BASE_URL override', () => {
		const workspacePath = '/tmp/fjcloud-worktree-default';
		const expectedWebPort = resolveDefaultPlaywrightWebPort(workspacePath);
		const expectedApiPort = resolveDefaultPlaywrightApiPort(workspacePath);
		const expectedBaseUrl = `http://localhost:${expectedWebPort}`;
		const expectedApiBaseUrl = `http://127.0.0.1:${expectedApiPort}`;
		const runtime = resolvePlaywrightRuntime({
			processEnv: {},
			repoEnv: {},
			webEnv: {},
			fallbackJwtSecret: 'fallback-jwt',
			workspacePath
		});

		expect(runtime.baseURL).toBe(expectedBaseUrl);
		expect(runtime.webServer).toEqual({
			command: `${PLAYWRIGHT_WEB_SERVER_COMMAND} --host localhost --port ${expectedWebPort} --strictPort`,
			env: runtime.webServerEnv,
			url: expectedBaseUrl,
			reuseExistingServer: false,
			timeout: PLAYWRIGHT_WEB_SERVER_TIMEOUT_MS
		});
		expect(runtime.webServerEnv.ADMIN_KEY).toBe(DEFAULT_PLAYWRIGHT_ADMIN_KEY);
		expect(runtime.webServerEnv.API_BASE_URL).toBe(expectedApiBaseUrl);
		expect(runtime.webServerEnv.API_URL).toBe(expectedApiBaseUrl);
		expect(runtime.webServerEnv[PLAYWRIGHT_API_PORT_ENV]).toBe(String(expectedApiPort));
		expect(runtime.webServerEnv.JWT_SECRET).toBe('fallback-jwt');
		expect(runtime.webServerEnv.ENVIRONMENT).toBe('local');
		expect(runtime.webServerEnv.FJCLOUD_ALLOW_LOOPBACK_SOURCE_ORIGINS).toBe('1');
		expect(runtime.webServerEnv.SKIP_EMAIL_VERIFICATION).toBe('1');
		expect(runtime.webServerEnv.API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION).toBe('1');
	});

	it('resolvePlaywrightRuntime enables migrations for the spawned provider-parity runtime only', () => {
		const workspacePath = '/tmp/fjcloud-worktree-source-migration-provider-parity';
		const expectedFlapjackDataDir = `../.local/flapjack-data-source-migration-provider-parity-${resolveDefaultPlaywrightFlapjackPort(workspacePath)}`;
		const parityRuntimes = [
			['test', '--grep', 'source migration provider parity'],
			['test', 'tests/e2e-ui/full/source_migration_provider_parity.spec.ts']
		].map((argv) => {
			const processEnv: MutableEnv = {};
			const runtime = resolvePlaywrightRuntime({
				processEnv,
				repoEnv: {},
				webEnv: {},
				fallbackJwtSecret: 'fallback-jwt',
				argv,
				workspacePath
			});
			return { processEnv, runtime };
		});
		const ordinaryRuntime = resolvePlaywrightRuntime({
			processEnv: {},
			repoEnv: {},
			webEnv: {},
			fallbackJwtSecret: 'fallback-jwt',
			workspacePath
		});

		for (const { processEnv, runtime: parityRuntime } of parityRuntimes) {
			expect(parityRuntime.webServer).toEqual(
				expect.objectContaining({
					gracefulShutdown: {
						signal: 'SIGTERM',
						timeout: PLAYWRIGHT_PROVIDER_PARITY_SHUTDOWN_TIMEOUT_MS
					}
				})
			);
			expect(parityRuntime.webServerEnv.FJCLOUD_ALGOLIA_MIGRATION_ENABLED).toBe('true');
			expect(parityRuntime.webServerEnv.FJ_ENABLE_MEILISEARCH_PREVIEW_LOOPBACK).toBe('1');
			expect(parityRuntime.webServerEnv.FJ_ENABLE_TYPESENSE_PREVIEW_LOOPBACK).toBe('1');
			expect(parityRuntime.webServerEnv.COMPOSE_PROFILES).toBe('source-providers');
			expect(parityRuntime.webServerEnv.LOCAL_MEILISEARCH_PORT).toBe(
				processEnv.LOCAL_MEILISEARCH_PORT
			);
			expect(parityRuntime.webServerEnv.LOCAL_TYPESENSE_PORT).toBe(processEnv.LOCAL_TYPESENSE_PORT);
			expect(processEnv.LOCAL_MEILISEARCH_PORT).toBe(
				String(resolveDefaultPlaywrightMeilisearchPort(workspacePath))
			);
			expect(processEnv.LOCAL_TYPESENSE_PORT).toBe(
				String(resolveDefaultPlaywrightTypesensePort(workspacePath))
			);
			expect(
				new Set([
					new URL(parityRuntime.baseURL).port,
					new URL(parityRuntime.webServerEnv.API_URL).port,
					new URL(parityRuntime.webServerEnv.FLAPJACK_URL).port,
					processEnv.LOCAL_MEILISEARCH_PORT,
					processEnv.LOCAL_TYPESENSE_PORT
				]).size
			).toBe(5);
			expect(parityRuntime.webServerEnv.MEILI_TEST_SECRET_CANARY).toBe(
				processEnv.MEILI_TEST_SECRET_CANARY
			);
			expect(parityRuntime.webServerEnv.TYPESENSE_STAGE2_BOOTSTRAP_CANARY).toBe(
				processEnv.TYPESENSE_STAGE2_BOOTSTRAP_CANARY
			);
			expect(processEnv.MEILI_TEST_SECRET_CANARY).toMatch(/^playwright-meili-canary-/);
			expect(processEnv.TYPESENSE_STAGE2_BOOTSTRAP_CANARY).toMatch(/^playwright-typesense-canary-/);
			expect(parityRuntime.webServerEnv.FJCLOUD_FLAPJACK_VERSION).toBeUndefined();
			expect(parityRuntime.webServerEnv.PLAYWRIGHT_FLAPJACK_DATA_DIR).toBe(expectedFlapjackDataDir);
		}
		expect(ordinaryRuntime.webServerEnv.FJCLOUD_ALGOLIA_MIGRATION_ENABLED).toBeUndefined();
		expect(ordinaryRuntime.webServer).not.toHaveProperty('gracefulShutdown');
		expect(ordinaryRuntime.webServerEnv.FJ_ENABLE_MEILISEARCH_PREVIEW_LOOPBACK).toBeUndefined();
		expect(ordinaryRuntime.webServerEnv.FJ_ENABLE_TYPESENSE_PREVIEW_LOOPBACK).toBeUndefined();
		expect(ordinaryRuntime.webServerEnv.PLAYWRIGHT_FLAPJACK_DATA_DIR).toBeUndefined();
	});

	it.each([
		['equals project flag', ['--project=chromium:email-verification']],
		['split project flag', ['--project', 'chromium:email-verification']]
	])(
		'resolvePlaywrightRuntime requires real email verification for sole %s selection',
		(_name, projectArgs) => {
			const workspacePath = '/tmp/fjcloud-worktree-email-verification';
			const processEnv: MutableEnv = {};
			const runtime = resolvePlaywrightRuntime({
				processEnv,
				repoEnv: {},
				webEnv: {},
				fallbackJwtSecret: 'fallback-jwt',
				argv: [
					'test',
					'tests/e2e-ui/full/auth-end-effects.spec.ts',
					...projectArgs,
					'--grep',
					'valid verification token shows success heading'
				],
				workspacePath
			});

			expect(runtime.webServer).toBeDefined();
			expectRequiredEmailVerification(runtime.webServerEnv);
			expect(processEnv[PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION_ENV]).toBe('1');
		}
	);

	it('resolvePlaywrightRuntime keeps local bypass when no project is selected', () => {
		const runtime = resolvePlaywrightRuntime({
			processEnv: {},
			repoEnv: {},
			webEnv: {},
			fallbackJwtSecret: 'fallback-jwt',
			argv: ['test', 'tests/e2e-ui/full/auth-end-effects.spec.ts']
		});

		expectLocalAutoVerificationBypass(runtime.webServerEnv);
	});

	it.each([
		'chromium',
		'chromium:public',
		'chromium:signup',
		'chromium:mocked',
		'chromium:onboarding',
		'chromium:customer-journeys',
		'chromium:admin',
		'chromium:accessibility'
	])('resolvePlaywrightRuntime keeps local bypass for %s', (projectName) => {
		const runtime = resolvePlaywrightRuntime({
			processEnv: {},
			repoEnv: {},
			webEnv: {},
			fallbackJwtSecret: 'fallback-jwt',
			argv: ['test', '--project', projectName]
		});

		expectLocalAutoVerificationBypass(runtime.webServerEnv);
	});

	it('resolvePlaywrightRuntime clears inherited email verification flag for ordinary local projects', () => {
		const processEnv: MutableEnv = {
			[PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION_ENV]: '1'
		};
		const runtime = resolvePlaywrightRuntime({
			processEnv,
			repoEnv: {},
			webEnv: {},
			fallbackJwtSecret: 'fallback-jwt',
			argv: ['test', '--project', 'chromium:signup']
		});

		expectLocalAutoVerificationBypass(runtime.webServerEnv);
		expect(processEnv[PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION_ENV]).toBeUndefined();
	});

	it('resolvePlaywrightRuntime deletes the inherited email verification flag from real process.env', async () => {
		await withIsolatedProcessEnv({ [PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION_ENV]: '1' }, async () => {
			const runtime = resolvePlaywrightRuntime({
				processEnv: process.env,
				repoEnv: {},
				webEnv: {},
				fallbackJwtSecret: 'fallback-jwt',
				argv: ['test', '--project', 'chromium:signup']
			});

			expectLocalAutoVerificationBypass(runtime.webServerEnv);
			expect(process.env[PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION_ENV]).toBeUndefined();
		});
	});

	it('resolvePlaywrightRuntime keeps local bypass for mixed project selections', () => {
		const runtime = resolvePlaywrightRuntime({
			processEnv: {},
			repoEnv: {},
			webEnv: {},
			fallbackJwtSecret: 'fallback-jwt',
			argv: ['test', '--project=chromium:email-verification', '--project', 'chromium:signup']
		});

		expectLocalAutoVerificationBypass(runtime.webServerEnv);
	});

	it('resolvePlaywrightRuntime keeps local bypass for variadic mixed project selections', () => {
		const runtime = resolvePlaywrightRuntime({
			processEnv: {},
			repoEnv: {},
			webEnv: {},
			fallbackJwtSecret: 'fallback-jwt',
			argv: [
				'test',
				'--project',
				'chromium:email-verification',
				'chromium:signup',
				'--reporter=line'
			]
		});

		expectLocalAutoVerificationBypass(runtime.webServerEnv);
	});

	it('resolvePlaywrightRuntime rejects wildcard selection of the email verification project', () => {
		expect(() =>
			resolvePlaywrightRuntime({
				processEnv: {},
				repoEnv: {},
				webEnv: {},
				fallbackJwtSecret: 'fallback-jwt',
				argv: ['test', '--project=chromium:email*']
			})
		).toThrow(
			'chromium:email-verification must be selected exactly; wildcard project selection is not allowed for email verification mode'
		);
	});

	it('resolvePlaywrightRuntime clears verification mode for explicit BASE_URL runs', () => {
		const processEnv: MutableEnv = {
			BASE_URL: 'http://127.0.0.1:4174',
			[PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION_ENV]: '1'
		};
		const runtime = resolvePlaywrightRuntime({
			processEnv,
			repoEnv: {},
			webEnv: {},
			fallbackJwtSecret: 'fallback-jwt',
			argv: ['test', '--project', 'chromium:email-verification']
		});

		expect(runtime.webServer).toBeUndefined();
		expect(runtime.webServerEnv[PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION_ENV]).toBeUndefined();
		expect(runtime.webServerEnv.SKIP_EMAIL_VERIFICATION).toBe('1');
		expect(runtime.webServerEnv.API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION).toBe('1');
		expect(processEnv[PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION_ENV]).toBeUndefined();
	});

	it('resolvePlaywrightRuntime uses explicit PLAYWRIGHT_API_PORT override for API_BASE_URL and API_URL', () => {
		const runtime = resolvePlaywrightRuntime({
			processEnv: { [PLAYWRIGHT_API_PORT_ENV]: '6411' },
			repoEnv: {},
			webEnv: {},
			fallbackJwtSecret: 'fallback-jwt'
		});
		expect(runtime.webServerEnv.API_BASE_URL).toBe('http://127.0.0.1:6411');
		expect(runtime.webServerEnv.API_URL).toBe('http://127.0.0.1:6411');
		expect(runtime.webServerEnv.LISTEN_ADDR).toBe('127.0.0.1:6411');
		expect(runtime.webServerEnv.S3_LISTEN_ADDR).toBe('127.0.0.1:6412');
		expect(runtime.webServerEnv[PLAYWRIGHT_API_PORT_ENV]).toBe('6411');
	});

	// Regression — workspace-isolated flapjack port (added 2026-05-26). Before this,
	// the flapjack URL was hardcoded to :7700 for every workspace, so concurrent
	// worktrees reused each other's flapjack with mismatched in-memory node admin keys
	// and every proxied index op failed flapjack auth with 403 "Invalid Application-ID
	// or API key" — the persistent synonyms-E2E proof-gate failure.
	it('resolveDefaultPlaywrightFlapjackPort is deterministic, in-band, and distinct from web+api ports', () => {
		const workspacePath = '/tmp/fjcloud-worktree-flapjack';
		const flapjackPort = resolveDefaultPlaywrightFlapjackPort(workspacePath);
		// Deterministic for the same workspace.
		expect(resolveDefaultPlaywrightFlapjackPort(workspacePath)).toBe(flapjackPort);
		// In the dedicated 9700–11699 band (above web 5600–7599 and API 7600–9599).
		expect(flapjackPort).toBeGreaterThanOrEqual(9700);
		expect(flapjackPort).toBeLessThanOrEqual(11699);
		// Never collides with the same workspace's web / API / S3-sidecar ports.
		const apiPort = resolveDefaultPlaywrightApiPort(workspacePath);
		const webPort = resolveDefaultPlaywrightWebPort(workspacePath);
		expect(flapjackPort).not.toBe(webPort);
		expect(flapjackPort).not.toBe(apiPort);
		expect(flapjackPort).not.toBe(apiPort + 1);
		// Different workspaces get different flapjack ports (the whole point of isolation).
		expect(resolveDefaultPlaywrightFlapjackPort('/tmp/fjcloud-worktree-other')).not.toBe(
			flapjackPort
		);
	});

	it('resolveDefaultPlaywrightFlapjackPort falls back to legacy 7700 only for an empty workspace path', () => {
		expect(resolveDefaultPlaywrightFlapjackPort('')).toBe(7700);
		expect(resolveDefaultPlaywrightFlapjackPort('   ')).toBe(7700);
	});

	it.each([
		['/tmp/fjcloud-worktree-browser-port-2263', 6001],
		['/tmp/fjcloud-worktree-browser-port-2526', 6567],
		['/tmp/fjcloud-worktree-browser-port-501', 6670],
		['/tmp/fjcloud-worktree-browser-port-926', 6670],
		['/tmp/fjcloud-worktree-browser-port-2316', 6670],
		['/tmp/fjcloud-worktree-browser-port-5037', 6670],
		['/tmp/fjcloud-worktree-browser-port-448', 6670],
		['/tmp/fjcloud-worktree-browser-port-710', 6698]
	])(
		'resolveDefaultPlaywrightWebPort skips Chromium-blocked port for %s',
		(workspacePath, safePort) => {
			expect(resolveDefaultPlaywrightWebPort(workspacePath)).toBe(safePort);
		}
	);

	it('resolvePlaywrightRuntime derives a per-workspace flapjack URL instead of hardcoded :7700', () => {
		const workspacePath = '/tmp/fjcloud-worktree-flapjack-runtime';
		const expectedFlapjackPort = resolveDefaultPlaywrightFlapjackPort(workspacePath);
		const expectedFlapjackUrl = `http://localhost:${expectedFlapjackPort}`;
		const processEnv: MutableEnv = {};
		const runtime = resolvePlaywrightRuntime({
			processEnv,
			repoEnv: {},
			webEnv: {},
			fallbackJwtSecret: 'fallback-jwt',
			workspacePath
		});
		// The spawned stack (flapjack + API) and the fixture process both see the
		// derived per-workspace URL — not the legacy shared :7700.
		expect(runtime.webServerEnv.FLAPJACK_URL).toBe(expectedFlapjackUrl);
		expect(runtime.webServerEnv.LOCAL_DEV_FLAPJACK_URL).toBe(expectedFlapjackUrl);
		expect(runtime.webServerEnv.FLAPJACK_URL).not.toBe(DEFAULT_FLAPJACK_URL);
		expect(runtime.webServerEnv[PLAYWRIGHT_FLAPJACK_PORT_ENV]).toBe(String(expectedFlapjackPort));
		// processEnv is mutated so seedIndex / resolveFixtureEnv provision nodes
		// against the same instance the stack runs (the load-bearing thread).
		expect(processEnv.FLAPJACK_URL).toBe(expectedFlapjackUrl);
		expect(processEnv.LOCAL_DEV_FLAPJACK_URL).toBe(expectedFlapjackUrl);
	});

	it('resolvePlaywrightRuntime honors an explicit PLAYWRIGHT_FLAPJACK_PORT override', () => {
		const processEnv: MutableEnv = { [PLAYWRIGHT_FLAPJACK_PORT_ENV]: '10250' };
		const runtime = resolvePlaywrightRuntime({
			processEnv,
			repoEnv: {},
			webEnv: {},
			fallbackJwtSecret: 'fallback-jwt'
		});
		expect(runtime.webServerEnv.FLAPJACK_URL).toBe('http://localhost:10250');
		expect(processEnv.FLAPJACK_URL).toBe('http://localhost:10250');
	});

	it('resolvePlaywrightRuntime preserves an explicit loopback FLAPJACK_URL override', () => {
		const processEnv: MutableEnv = { FLAPJACK_URL: 'http://127.0.0.1:7799' };
		const runtime = resolvePlaywrightRuntime({
			processEnv,
			repoEnv: {},
			webEnv: {},
			fallbackJwtSecret: 'fallback-jwt'
		});
		// An operator-pinned FLAPJACK_URL must not be overwritten by the derived port.
		expect(processEnv.FLAPJACK_URL).toBe('http://127.0.0.1:7799');
		expect(runtime.webServerEnv.FLAPJACK_URL).toBe('http://127.0.0.1:7799');
	});

	it('resolvePlaywrightRuntime lets explicit process env override stale repo Flapjack source config', () => {
		const processEnv: MutableEnv = { FLAPJACK_DEV_DIR: '/tmp/flapjack-clean' };
		const runtime = resolvePlaywrightRuntime({
			processEnv,
			repoEnv: { FLAPJACK_DEV_DIR: '/tmp/flapjack-dirty' },
			webEnv: {},
			fallbackJwtSecret: 'fallback-jwt'
		});

		expect(runtime.webServerEnv.FLAPJACK_DEV_DIR).toBe('/tmp/flapjack-clean');
	});

	it('uses the local stack launcher base command so setup:user has API availability without manual startup', () => {
		expect(PLAYWRIGHT_WEB_SERVER_COMMAND).toBe(
			'../scripts/playwright_local_stack.sh --force-api-restart'
		);
	});

	it('uses the web-only launcher for public-only smoke selections', () => {
		const workspacePath = '/tmp/fjcloud-worktree-public';
		const expectedPort = resolveDefaultPlaywrightWebPort(workspacePath);
		const runtime = resolvePlaywrightRuntime({
			processEnv: {},
			repoEnv: {},
			webEnv: {},
			fallbackJwtSecret: 'fallback-jwt',
			argv: ['test', 'smoke/public-editor_dialog.spec.ts', '--project=chromium:public'],
			workspacePath
		});

		expect(runtime.webServer?.command).toBe(
			`${PLAYWRIGHT_WEB_ONLY_SERVER_COMMAND} --host localhost --port ${expectedPort} --strictPort`
		);
		expect(runtime.webServer?.reuseExistingServer).toBe(false);
	});

	it.each([
		['equals project flag', ['--project=chromium:public']],
		['split project flag', ['--project', 'chromium:public']]
	])(
		'uses the local stack launcher for the public infrastructure browser owner with %s',
		(_name, projectArgs) => {
			const workspacePath = '/tmp/fjcloud-worktree-public-infrastructure';
			const expectedPort = resolveDefaultPlaywrightWebPort(workspacePath);
			const expectedApiPort = resolveDefaultPlaywrightApiPort(workspacePath);
			const expectedApiUrl = `http://127.0.0.1:${expectedApiPort}`;
			const processEnv: MutableEnv = {};
			const runtime = resolvePlaywrightRuntime({
				processEnv,
				repoEnv: {},
				webEnv: {},
				fallbackJwtSecret: 'fallback-jwt',
				argv: ['test', 'tests/e2e-ui/full/public-infrastructure.spec.ts', ...projectArgs],
				workspacePath
			});

			expect(runtime.webServer?.command).toBe(
				`${PLAYWRIGHT_WEB_SERVER_COMMAND} --host localhost --port ${expectedPort} --strictPort`
			);
			expect(processEnv.API_BASE_URL).toBe(expectedApiUrl);
			expect(processEnv.API_URL).toBe(expectedApiUrl);
			expect(processEnv[PLAYWRIGHT_API_PORT_ENV]).toBe(String(expectedApiPort));
			expect(runtime.webServerEnv.API_BASE_URL).toBe(expectedApiUrl);
			expect(runtime.webServerEnv.API_URL).toBe(expectedApiUrl);
			expect(runtime.webServerEnv[PLAYWRIGHT_API_PORT_ENV]).toBe(String(expectedApiPort));
			expect(runtime.webServerEnv.LISTEN_ADDR).toBe(`127.0.0.1:${expectedApiPort}`);
			expect(runtime.webServerEnv.S3_LISTEN_ADDR).toBe(`127.0.0.1:${expectedApiPort + 1}`);
		}
	);

	it.each([
		['equals project flag', ['--project=chromium:public']],
		['split project flag', ['--project', 'chromium:public']]
	])(
		'uses the local stack launcher for line-targeted public infrastructure reruns with %s',
		(_name, projectArgs) => {
			const workspacePath = '/tmp/fjcloud-worktree-public-infrastructure-line-filter';
			const expectedPort = resolveDefaultPlaywrightWebPort(workspacePath);
			const expectedApiPort = resolveDefaultPlaywrightApiPort(workspacePath);
			const expectedApiUrl = `http://127.0.0.1:${expectedApiPort}`;
			const processEnv: MutableEnv = {};
			const runtime = resolvePlaywrightRuntime({
				processEnv,
				repoEnv: {},
				webEnv: {},
				fallbackJwtSecret: 'fallback-jwt',
				argv: ['test', 'tests/e2e-ui/full/public-infrastructure.spec.ts:10:4', ...projectArgs],
				workspacePath
			});

			expect(runtime.webServer?.command).toBe(
				`${PLAYWRIGHT_WEB_SERVER_COMMAND} --host localhost --port ${expectedPort} --strictPort`
			);
			expect(processEnv.API_BASE_URL).toBe(expectedApiUrl);
			expect(processEnv.API_URL).toBe(expectedApiUrl);
			expect(runtime.webServerEnv.API_BASE_URL).toBe(expectedApiUrl);
			expect(runtime.webServerEnv.API_URL).toBe(expectedApiUrl);
		}
	);

	it.each([
		['equals project flag', ['--project=chromium:public']],
		['split project flag', ['--project', 'chromium:public']]
	])(
		'fails closed to the local stack launcher for grep-only chromium:public reruns with %s',
		(_name, projectArgs) => {
			const workspacePath = '/tmp/fjcloud-worktree-public-infrastructure-grep-filter';
			const expectedPort = resolveDefaultPlaywrightWebPort(workspacePath);
			const expectedApiPort = resolveDefaultPlaywrightApiPort(workspacePath);
			const expectedApiUrl = `http://127.0.0.1:${expectedApiPort}`;
			const processEnv: MutableEnv = {};
			const runtime = resolvePlaywrightRuntime({
				processEnv,
				repoEnv: {},
				webEnv: {},
				fallbackJwtSecret: 'fallback-jwt',
				argv: ['test', ...projectArgs, '--grep', 'raw public JSON is anonymous'],
				workspacePath
			});

			expect(runtime.webServer?.command).toBe(
				`${PLAYWRIGHT_WEB_SERVER_COMMAND} --host localhost --port ${expectedPort} --strictPort`
			);
			expect(processEnv.API_BASE_URL).toBe(expectedApiUrl);
			expect(processEnv.API_URL).toBe(expectedApiUrl);
			expect(runtime.webServerEnv.API_BASE_URL).toBe(expectedApiUrl);
			expect(runtime.webServerEnv.API_URL).toBe(expectedApiUrl);
		}
	);

	it('uses explicit PLAYWRIGHT_WEB_PORT override for webServer and baseURL', () => {
		const processEnv: MutableEnv = {
			[PLAYWRIGHT_WEB_PORT_ENV]: '6123'
		};
		const runtime = resolvePlaywrightRuntime({
			processEnv,
			repoEnv: {},
			webEnv: {},
			fallbackJwtSecret: 'fallback-jwt'
		});

		expect(runtime.baseURL).toBe('http://localhost:6123');
		expect(runtime.webServer?.url).toBe('http://localhost:6123');
		expect(runtime.webServer?.command).toContain('--port 6123');
		expect(processEnv.BASE_URL).toBe('http://localhost:6123');
	});

	it('resolvePlaywrightRuntime prefers web ADMIN_KEY then repo then process ADMIN_KEY', () => {
		const cases = [
			{
				name: 'web ADMIN_KEY',
				runtime: resolvePlaywrightRuntime({
					processEnv: { ADMIN_KEY: 'process-admin' },
					repoEnv: { ADMIN_KEY: 'repo-admin' },
					webEnv: { ADMIN_KEY: 'web-admin' },
					fallbackJwtSecret: 'fallback-jwt'
				}),
				expected: 'web-admin'
			},
			{
				name: 'repo ADMIN_KEY',
				runtime: resolvePlaywrightRuntime({
					processEnv: { ADMIN_KEY: 'process-admin' },
					repoEnv: { ADMIN_KEY: 'repo-admin' },
					webEnv: {},
					fallbackJwtSecret: 'fallback-jwt'
				}),
				expected: 'repo-admin'
			},
			{
				name: 'process ADMIN_KEY',
				runtime: resolvePlaywrightRuntime({
					processEnv: { ADMIN_KEY: 'process-admin' },
					repoEnv: {},
					webEnv: {},
					fallbackJwtSecret: 'fallback-jwt'
				}),
				expected: 'process-admin'
			}
		];

		for (const { name, runtime, expected } of cases) {
			expect(runtime.webServerEnv.ADMIN_KEY, name).toBe(expected);
		}
	});

	it('project contracts preserve narrow-lane wiring for setup and admin/browser projects', () => {
		expect(projectContractsByName['setup:user']?.testMatch).toEqual(/fixtures\/auth\.setup\.ts/);
		expect(projectContractsByName['setup:admin']?.testMatch).toEqual(
			/fixtures\/admin\.auth\.setup\.ts/
		);
		expect(projectContractsByName['setup:onboarding']?.testMatch).toEqual(
			/fixtures\/onboarding\.auth\.setup\.ts/
		);
		expect(projectContractsByName['setup:customer-journeys']?.testMatch).toEqual(
			/fixtures\/customer-journeys\.auth\.setup\.ts/
		);

		expect(projectContractsByName.chromium?.dependencies).toEqual(['setup:user']);
		expect(projectContractsByName.chromium?.use?.desktopBrowser).toBe('chromium');
		expect(projectContractsByName.chromium?.use?.storageState).toBe(PLAYWRIGHT_STORAGE_STATE.user);

		expect(projectContractsByName['chromium:accessibility']?.dependencies).toEqual([
			'setup:user',
			'setup:admin'
		]);
		expect(projectContractsByName['chromium:accessibility']?.use?.desktopBrowser).toBe('chromium');
		expect(projectContractsByName['chromium:accessibility']?.use?.storageState).toBeUndefined();

		expect(projectContractsByName['chromium:onboarding']?.dependencies).toEqual([
			'setup:onboarding'
		]);
		expect(projectContractsByName['chromium:onboarding']?.use?.desktopBrowser).toBe('chromium');
		expect(projectContractsByName['chromium:onboarding']?.use?.storageState).toBe(
			PLAYWRIGHT_STORAGE_STATE.onboarding
		);
		expect(projectContractsByName['chromium:customer-journeys']?.dependencies).toEqual([
			'setup:customer-journeys'
		]);
		expect(projectContractsByName['chromium:customer-journeys']?.use?.desktopBrowser).toBe(
			'chromium'
		);
		expect(projectContractsByName['chromium:customer-journeys']?.use?.storageState).toBe(
			PLAYWRIGHT_STORAGE_STATE.customerJourneys
		);
		expect(projectContractsByName['chromium:signup']?.dependencies).toBeUndefined();
		expect(projectContractsByName['chromium:signup']?.use?.desktopBrowser).toBe('chromium');
		expect(projectContractsByName['chromium:signup']?.use?.storageState).toBeUndefined();
		expect(projectContractsByName['chromium:security-headers']?.dependencies).toBeUndefined();
		expect(projectContractsByName['chromium:security-headers']?.use?.desktopBrowser).toBe(
			'chromium'
		);
		expect(projectContractsByName['chromium:security-headers']?.use?.storageState).toBeUndefined();
		expect(projectContractsByName[EMAIL_VERIFICATION_PROJECT_NAME]?.testMatch).toEqual(
			/e2e-ui\/full\/auth-end-effects\.spec\.ts/
		);
		expect(projectContractsByName[EMAIL_VERIFICATION_PROJECT_NAME]?.dependencies).toBeUndefined();
		expect(projectContractsByName[EMAIL_VERIFICATION_PROJECT_NAME]?.use?.desktopBrowser).toBe(
			'chromium'
		);
		expect(
			projectContractsByName[EMAIL_VERIFICATION_PROJECT_NAME]?.use?.storageState
		).toBeUndefined();
		expect(projectContractsByName['chromium:mocked']?.dependencies).toEqual(['setup:user']);
		expect(projectContractsByName['chromium:mocked']?.use?.desktopBrowser).toBe('chromium');
		expect(projectContractsByName['chromium:mocked']?.use?.storageState).toBe(
			PLAYWRIGHT_STORAGE_STATE.user
		);

		expect(projectContractsByName['chromium:admin']?.dependencies).toEqual(['setup:admin']);
		expect(projectContractsByName['chromium:admin']?.use?.desktopBrowser).toBe('chromium');
		expect(projectContractsByName['chromium:admin']?.use?.storageState).toBe(
			PLAYWRIGHT_STORAGE_STATE.admin
		);

		// Firefox/WebKit projects were dropped 2026-05-02 to cut CI cycle time.
		// Playwright-on-Linux WebKit isn't real Safari (no ITP, no Apple Pay,
		// no Stripe 3DS quirks), and Firefox is ~3-6% of users — both costs
		// outweigh their bug-catching value at paid-beta scale.
		expect(projectContractsByName['firefox:public']).toBeUndefined();
		expect(projectContractsByName['firefox:smoke']).toBeUndefined();
		expect(projectContractsByName['webkit:public']).toBeUndefined();
		expect(projectContractsByName['webkit:smoke']).toBeUndefined();
	});

	describe('resolveFixtureEnv', () => {
		it('returns all defaults when no env overrides are set', () => {
			const env = resolveFixtureEnv({});
			expect(env).toEqual({
				apiUrl: DEFAULT_API_URL,
				adminKey: undefined,
				userEmail: undefined,
				userPassword: undefined,
				testRegion: DEFAULT_TEST_REGION,
				flapjackUrl: DEFAULT_FLAPJACK_URL
			});
		});

		it('overrides apiUrl from API_URL env var', () => {
			const env = resolveFixtureEnv({ API_URL: 'http://127.0.0.1:9999' });
			expect(env.apiUrl).toBe('http://127.0.0.1:9999');
		});

		it('overrides adminKey from E2E_ADMIN_KEY env var', () => {
			const env = resolveFixtureEnv({ E2E_ADMIN_KEY: 'my-admin-key' });
			expect(env.adminKey).toBe('my-admin-key');
		});

		it('falls back to ADMIN_KEY when E2E_ADMIN_KEY is unset', () => {
			const env = resolveFixtureEnv({ ADMIN_KEY: 'server-admin-key' });
			expect(env.adminKey).toBe('server-admin-key');
		});

		it('overrides userEmail from E2E_USER_EMAIL env var', () => {
			const env = resolveFixtureEnv({ E2E_USER_EMAIL: 'user@test.com' });
			expect(env.userEmail).toBe('user@test.com');
		});

		it('overrides userPassword from E2E_USER_PASSWORD env var', () => {
			const env = resolveFixtureEnv({ E2E_USER_PASSWORD: 'secret123' });
			expect(env.userPassword).toBe('secret123');
		});

		it('overrides testRegion from E2E_TEST_REGION env var', () => {
			const env = resolveFixtureEnv({ E2E_TEST_REGION: 'eu-west-1' });
			expect(env.testRegion).toBe('eu-west-1');
		});

		it('overrides flapjackUrl from FLAPJACK_URL env var', () => {
			const env = resolveFixtureEnv({ FLAPJACK_URL: 'http://127.0.0.1:8800' });
			expect(env.flapjackUrl).toBe('http://127.0.0.1:8800');
		});

		it('rejects non-loopback API_URL overrides', () => {
			expect(() => resolveFixtureEnv({ API_URL: 'https://api.example.com' })).toThrow(
				'API_URL must use a local loopback host (localhost, 127.0.0.1, or [::1]) for credentialed local browser runs'
			);
		});

		it('rejects non-loopback FLAPJACK_URL overrides', () => {
			expect(() => resolveFixtureEnv({ FLAPJACK_URL: 'https://flapjack.example.com' })).toThrow(
				'FLAPJACK_URL must use a local loopback host (localhost, 127.0.0.1, or [::1]) for credentialed local browser runs'
			);
		});

		it('returns undefined for optional fields when env vars are not set', () => {
			const env = resolveFixtureEnv({});
			expect(env.adminKey).toBeUndefined();
			expect(env.userEmail).toBeUndefined();
			expect(env.userPassword).toBeUndefined();
		});

		it('resolves all fields simultaneously when all env vars are set', () => {
			const env = resolveFixtureEnv({
				API_URL: 'http://localhost:3001',
				E2E_ADMIN_KEY: 'admin-key',
				E2E_USER_EMAIL: 'e2e@test.com',
				E2E_USER_PASSWORD: 'pass',
				E2E_TEST_REGION: 'ap-south-1',
				FLAPJACK_URL: 'http://127.0.0.1:7700'
			});
			expect(env).toEqual({
				apiUrl: 'http://localhost:3001',
				adminKey: 'admin-key',
				userEmail: 'e2e@test.com',
				userPassword: 'pass',
				testRegion: 'ap-south-1',
				flapjackUrl: 'http://127.0.0.1:7700'
			});
		});
	});

	describe('required fixture auth env helpers', () => {
		it('resolves required user credentials from fixture env', () => {
			expect(
				resolveRequiredFixtureUserCredentials({
					E2E_USER_EMAIL: 'user@test.com',
					E2E_USER_PASSWORD: 'secret123'
				})
			).toEqual({
				email: 'user@test.com',
				password: 'secret123'
			});
		});

		it('rejects missing required user credentials', () => {
			expect(() => resolveRequiredFixtureUserCredentials({})).toThrow(
				'E2E_USER_EMAIL and E2E_USER_PASSWORD must be set to run browser-unmocked tests'
			);
		});

		it('rejects whitespace-only user email', () => {
			expect(() =>
				resolveRequiredFixtureUserCredentials({
					E2E_USER_EMAIL: '  \t ',
					E2E_USER_PASSWORD: 'secret123'
				})
			).toThrow('E2E_USER_EMAIL and E2E_USER_PASSWORD must be set to run browser-unmocked tests');
		});

		it('rejects whitespace-only user password', () => {
			expect(() =>
				resolveRequiredFixtureUserCredentials({
					E2E_USER_EMAIL: 'user@test.com',
					E2E_USER_PASSWORD: '   '
				})
			).toThrow('E2E_USER_EMAIL and E2E_USER_PASSWORD must be set to run browser-unmocked tests');
		});

		it('trims user email but preserves the exact password value', () => {
			expect(
				resolveRequiredFixtureUserCredentials({
					E2E_USER_EMAIL: '  user@test.com  ',
					E2E_USER_PASSWORD: '  secret123  '
				})
			).toEqual({
				email: 'user@test.com',
				password: '  secret123  '
			});
		});

		it('resolves required admin key from fixture env', () => {
			expect(
				resolveRequiredFixtureAdminKey({
					E2E_ADMIN_KEY: 'admin-key'
				})
			).toBe('admin-key');
		});

		it('falls back to ADMIN_KEY when E2E_ADMIN_KEY is unset', () => {
			expect(
				resolveRequiredFixtureAdminKey({
					ADMIN_KEY: 'server-admin-key'
				})
			).toBe('server-admin-key');
		});

		it('rejects missing required admin key', () => {
			expect(() => resolveRequiredFixtureAdminKey({})).toThrow(
				'E2E_ADMIN_KEY must be set to run admin browser-unmocked tests'
			);
		});

		it('rejects whitespace-only admin key', () => {
			expect(() =>
				resolveRequiredFixtureAdminKey({
					E2E_ADMIN_KEY: '  \t\n  '
				})
			).toThrow('E2E_ADMIN_KEY must be set to run admin browser-unmocked tests');
		});

		it('preserves the exact admin key value', () => {
			expect(
				resolveRequiredFixtureAdminKey({
					E2E_ADMIN_KEY: '  admin-key  '
				})
			).toBe('  admin-key  ');
		});
	});

	describe('applyPlaywrightProcessEnvDefaults full 3-source precedence', () => {
		it('resolves E2E_ADMIN_KEY through the complete 7-position chain with all sources conflicting', () => {
			// Positions: 1=processEnv.E2E_ADMIN_KEY, 2=webEnv.E2E_ADMIN_KEY,
			// 3=repoEnv.E2E_ADMIN_KEY, 4=webEnv.ADMIN_KEY, 5=repoEnv.ADMIN_KEY,
			// 6=processEnv.ADMIN_KEY, 7=DEFAULT_PLAYWRIGHT_ADMIN_KEY
			const cases: Array<{ label: string; input: EnvDefaultsInput; expected: string }> = [
				{
					label: 'position 1 wins',
					input: {
						processEnv: { E2E_ADMIN_KEY: 'pos1', ADMIN_KEY: 'pos6' },
						repoEnv: { E2E_ADMIN_KEY: 'pos3', ADMIN_KEY: 'pos5' },
						webEnv: { E2E_ADMIN_KEY: 'pos2', ADMIN_KEY: 'pos4' }
					},
					expected: 'pos1'
				},
				{
					label: 'position 2 wins',
					input: {
						processEnv: { ADMIN_KEY: 'pos6' },
						repoEnv: { E2E_ADMIN_KEY: 'pos3', ADMIN_KEY: 'pos5' },
						webEnv: { E2E_ADMIN_KEY: 'pos2', ADMIN_KEY: 'pos4' }
					},
					expected: 'pos2'
				},
				{
					label: 'position 3 wins',
					input: {
						processEnv: { ADMIN_KEY: 'pos6' },
						repoEnv: { E2E_ADMIN_KEY: 'pos3', ADMIN_KEY: 'pos5' },
						webEnv: { ADMIN_KEY: 'pos4' }
					},
					expected: 'pos3'
				},
				{
					label: 'position 4 wins',
					input: {
						processEnv: { ADMIN_KEY: 'pos6' },
						repoEnv: { ADMIN_KEY: 'pos5' },
						webEnv: { ADMIN_KEY: 'pos4' }
					},
					expected: 'pos4'
				},
				{
					label: 'position 5 wins',
					input: {
						processEnv: { ADMIN_KEY: 'pos6' },
						repoEnv: { ADMIN_KEY: 'pos5' },
						webEnv: {}
					},
					expected: 'pos5'
				},
				{
					label: 'position 6 wins',
					input: {
						processEnv: { ADMIN_KEY: 'pos6' },
						repoEnv: {},
						webEnv: {}
					},
					expected: 'pos6'
				},
				{
					label: 'position 7 wins',
					input: {
						processEnv: {},
						repoEnv: {},
						webEnv: {}
					},
					expected: DEFAULT_PLAYWRIGHT_ADMIN_KEY
				}
			];

			for (const { label, input, expected } of cases) {
				expect(applyEnvDefaults(input).E2E_ADMIN_KEY, label).toBe(expected);
			}
		});

		it('resolves E2E_USER_EMAIL through the complete 7-position chain with all sources conflicting', () => {
			// Positions: 1=processEnv.E2E_USER_EMAIL, 2=webEnv.E2E_USER_EMAIL,
			// 3=repoEnv.E2E_USER_EMAIL, 4=processEnv.SEED_USER_EMAIL,
			// 5=repoEnv.SEED_USER_EMAIL, 6=webEnv.SEED_USER_EMAIL, 7=DEFAULT
			const cases: Array<{ label: string; input: EnvDefaultsInput; expected: string }> = [
				{
					label: 'position 1 wins',
					input: {
						processEnv: { E2E_USER_EMAIL: 'pos1', SEED_USER_EMAIL: 'pos4' },
						repoEnv: { E2E_USER_EMAIL: 'pos3', SEED_USER_EMAIL: 'pos5' },
						webEnv: { E2E_USER_EMAIL: 'pos2', SEED_USER_EMAIL: 'pos6' }
					},
					expected: 'pos1'
				},
				{
					label: 'position 4 wins',
					input: {
						processEnv: { SEED_USER_EMAIL: 'pos4' },
						repoEnv: { SEED_USER_EMAIL: 'pos5' },
						webEnv: { SEED_USER_EMAIL: 'pos6' }
					},
					expected: 'pos4'
				},
				{
					label: 'position 5 wins',
					input: {
						processEnv: {},
						repoEnv: { SEED_USER_EMAIL: 'pos5' },
						webEnv: { SEED_USER_EMAIL: 'pos6' }
					},
					expected: 'pos5'
				},
				{
					label: 'position 6 wins',
					input: {
						processEnv: {},
						repoEnv: {},
						webEnv: { SEED_USER_EMAIL: 'pos6' }
					},
					expected: 'pos6'
				},
				{
					label: 'position 7 wins',
					input: {
						processEnv: {},
						repoEnv: {},
						webEnv: {}
					},
					expected: DEFAULT_E2E_USER_EMAIL
				}
			];

			for (const { label, input, expected } of cases) {
				expect(applyEnvDefaults(input).E2E_USER_EMAIL, label).toBe(expected);
			}
		});
	});

	describe('PLAYWRIGHT_PROJECT_CONTRACTS spec file routing', () => {
		it('source migration provider parity disables credential-bearing failure artifacts', () => {
			const specPath = 'tests/e2e-ui/full/source_migration_provider_parity.spec.ts';
			const specSource = readFileSync(join(process.cwd(), specPath), 'utf8');
			const testUseOverride = specSource.match(/test\.use\(\{[\s\S]*?\}\);/u)?.[0];

			expect(testUseOverride).toBeDefined();
			expect(testUseOverride).toMatch(/\btrace:\s*'off'/u);
			expect(testUseOverride).toMatch(/\bscreenshot:\s*'off'/u);
		});

		it('routes the browser accessibility catalog to its sole project owner', () => {
			const specPath = 'tests/e2e-ui/full/accessibility.spec.ts';

			expect(projectContractsByName['chromium:accessibility']?.testMatch.test(specPath)).toBe(true);
			for (const projectName of [
				'chromium',
				'chromium:public',
				'chromium:admin',
				'chromium:mocked'
			]) {
				expect(projectContractsByName[projectName]?.testMatch.test(specPath), projectName).toBe(
					false
				);
			}
		});

		it('keeps API-backed blank-browser lifecycle specs out of the web-only public owner', () => {
			const fullSpecDir = join(process.cwd(), 'tests/e2e-ui/full');
			const fullStackLifecycleSpecs = [
				'tests/e2e-ui/full/account-delete.spec.ts',
				'tests/e2e-ui/full/account-password.spec.ts',
				'tests/e2e-ui/full/auth-end-effects.spec.ts'
			];
			const stalePublicLifecycleSpecNames = [
				'public-account-delete.spec.ts',
				'public-account-password.spec.ts',
				'public-auth-end-effects.spec.ts'
			];

			for (const specPath of fullStackLifecycleSpecs) {
				expect(projectContractsByName.chromium?.testMatch.test(specPath), specPath).toBe(true);
				expect(projectContractsByName['chromium:public']?.testMatch.test(specPath), specPath).toBe(
					false
				);
			}
			for (const specName of stalePublicLifecycleSpecNames) {
				expect(existsSync(join(fullSpecDir, specName)), specName).toBe(false);
			}
		});

		it('keeps API-backed auth form effects out of the web-only public owner', () => {
			const publicAuthPagesPath = join(
				process.cwd(),
				'tests/e2e-ui/full/public-auth-pages.spec.ts'
			);
			const fullStackAuthEffectsSpecPath = 'tests/e2e-ui/full/auth-form-api-effects.spec.ts';
			const publicAuthPagesSource = readFileSync(publicAuthPagesPath, 'utf8');

			expect(
				projectContractsByName['chromium:public']?.testMatch.test(
					'tests/e2e-ui/full/public-auth-pages.spec.ts'
				)
			).toBe(true);
			expect(existsSync(join(process.cwd(), fullStackAuthEffectsSpecPath))).toBe(true);
			expect(projectContractsByName.chromium?.testMatch.test(fullStackAuthEffectsSpecPath)).toBe(
				true
			);
			expect(
				projectContractsByName['chromium:public']?.testMatch.test(fullStackAuthEffectsSpecPath)
			).toBe(false);
			expect(publicAuthPagesSource).not.toMatch(/\bcreateUser\b/);
			expect(publicAuthPagesSource).not.toMatch(/E2E_USER_(EMAIL|PASSWORD)/);
		});

		it('auth.spec.ts matches the chromium project (setup:user dependency)', () => {
			const specPath = 'tests/e2e-ui/full/auth.spec.ts';
			expect(projectContractsByName.chromium?.testMatch.test(specPath)).toBe(true);
			expect(projectContractsByName['chromium:admin']?.testMatch.test(specPath)).toBe(false);
			expect(projectContractsByName.chromium?.dependencies).toEqual(['setup:user']);
		});

		it('account.spec.ts matches the chromium project (setup:user dependency)', () => {
			const specPath = 'tests/e2e-ui/full/account.spec.ts';
			expect(projectContractsByName.chromium?.testMatch.test(specPath)).toBe(true);
			expect(projectContractsByName['chromium:admin']?.testMatch.test(specPath)).toBe(false);
			expect(projectContractsByName.chromium?.dependencies).toEqual(['setup:user']);
		});

		it('admin/customer-detail.spec.ts matches chromium:admin (setup:admin dependency)', () => {
			const specPath = 'tests/e2e-ui/full/admin/customer-detail.spec.ts';
			expect(projectContractsByName['chromium:admin']?.testMatch.test(specPath)).toBe(true);
			expect(projectContractsByName.chromium?.testMatch.test(specPath)).toBe(false);
			expect(projectContractsByName['chromium:admin']?.dependencies).toEqual(['setup:admin']);
		});

		it('admin specs do NOT match the non-admin chromium project', () => {
			const adminSpecs = [
				'tests/e2e-ui/full/admin/customer-detail.spec.ts',
				'tests/e2e-ui/full/admin/some-future-admin.spec.ts'
			];
			for (const specPath of adminSpecs) {
				expect(projectContractsByName.chromium?.testMatch.test(specPath)).toBe(false);
			}
		});

		it('signup_to_paid_invoice.spec.ts matches chromium:signup only', () => {
			const specPath = 'tests/e2e-ui/full/signup_to_paid_invoice.spec.ts';
			expect(projectContractsByName['chromium:signup']?.testMatch.test(specPath)).toBe(true);
			expect(projectContractsByName.chromium?.testMatch.test(specPath)).toBe(false);
			expect(projectContractsByName['chromium:customer-journeys']?.testMatch.test(specPath)).toBe(
				false
			);
			expect(projectContractsByName['chromium:signup']?.dependencies).toBeUndefined();
			expect(projectContractsByName['chromium:signup']?.use?.storageState).toBeUndefined();
		});

		it('security_headers.spec.ts matches the self-authenticated security-headers project only', () => {
			const specPath = 'tests/e2e-ui/full/security_headers.spec.ts';
			expect(projectContractsByName['chromium:security-headers']?.testMatch.test(specPath)).toBe(
				true
			);
			expect(projectContractsByName.chromium?.testMatch.test(specPath)).toBe(false);
			expect(projectContractsByName['chromium:security-headers']?.dependencies).toBeUndefined();
			expect(
				projectContractsByName['chromium:security-headers']?.use?.storageState
			).toBeUndefined();
		});

		it('console_upgrade_to_shared.spec.ts matches chromium:mocked only', () => {
			const specPath = 'tests/e2e-ui/mocked/console_upgrade_to_shared.spec.ts';
			expect(projectContractsByName['chromium:mocked']?.testMatch.test(specPath)).toBe(true);
			expect(projectContractsByName.chromium?.testMatch.test(specPath)).toBe(false);
			expect(projectContractsByName['chromium:public']?.testMatch.test(specPath)).toBe(false);
			expect(projectContractsByName['chromium:admin']?.testMatch.test(specPath)).toBe(false);
			expect(projectContractsByName['chromium:mocked']?.dependencies).toEqual(['setup:user']);
			expect(projectContractsByName['chromium:mocked']?.use?.storageState).toBe(
				PLAYWRIGHT_STORAGE_STATE.user
			);
		});

		// Stage 1 red guard — the polished-beta staging verification spec runs under the
		// chromium project, whose `setup:user` dependency and `storageState` already supply
		// a logged-in customer baseline. The spec must NOT re-blank that session with an
		// empty `storageState` override; Stage 2 removes the override so the lanes can share
		// the tracked customer session. This guard fails red at HEAD until the override is
		// deleted, and documents project-level storage state as the canonical auth baseline.
		it('polished_beta_staging_verify.spec.ts routes to chromium and drops the empty storageState override', () => {
			const specPath = 'tests/e2e-ui/full/polished_beta_staging_verify.spec.ts';
			const specSource = readFileSync(join(process.cwd(), specPath), 'utf8');

			const emptyStorageStateProperty = String.raw`(?:cookies|origins)\s*:\s*\[\s*\]`;
			const emptyStorageStateOverride = new RegExp(
				String.raw`storageState\s*:\s*\{\s*` +
					String.raw`(?=[^{}]*\bcookies\s*:\s*\[\s*\])` +
					String.raw`(?=[^{}]*\borigins\s*:\s*\[\s*\])` +
					String.raw`${emptyStorageStateProperty}\s*,\s*${emptyStorageStateProperty}\s*,?\s*\}`
			);
			for (const overrideSource of [
				`test.use({ storageState: { cookies: [], origins: [] } })`,
				`test.use({ storageState: { origins: [], cookies: [] } })`,
				`test.use({ storageState: { origins: [], cookies: [], } })`,
				`test.use({
					storageState: {
						origins: [],
						cookies: [],
					},
				})`
			]) {
				expect(overrideSource).toMatch(emptyStorageStateOverride);
			}
			for (const overrideSource of [
				`test.use({ storageState: PLAYWRIGHT_STORAGE_STATE.user })`,
				`test.use({ storageState: { cookies: [{ name: 'fj_session' }], origins: [] } })`
			]) {
				expect(overrideSource).not.toMatch(emptyStorageStateOverride);
			}

			// Scope the guard to executable `test.use(...)` calls so an empty-override
			// shape that survives only inside a comment or string literal (e.g. the
			// classification note that mentions `test.use({ storageState })`) cannot
			// false-fail the contract once Stage 2 deletes the real override.
			const stripCommentsAndStringLiterals = (source: string): string =>
				source
					.replace(/\/\*[\s\S]*?\*\//g, ' ')
					.replace(/\/\/[^\n]*/g, ' ')
					.replace(/'(?:\\.|[^'\\])*'/g, "''")
					.replace(/"(?:\\.|[^"\\])*"/g, '""')
					.replace(/`(?:\\.|[^`\\])*`/g, '``');
			const extractTestUseCalls = (source: string): string[] => {
				const executable = stripCommentsAndStringLiterals(source);
				const marker = 'test.use(';
				const calls: string[] = [];
				let start = executable.indexOf(marker);
				while (start !== -1) {
					let depth = 0;
					let end = start + marker.length - 1;
					for (let i = start + marker.length - 1; i < executable.length; i++) {
						const ch = executable[i];
						if (ch === '(') depth++;
						else if (ch === ')') {
							depth--;
							if (depth === 0) {
								end = i;
								break;
							}
						}
					}
					calls.push(executable.slice(start, end + 1));
					start = executable.indexOf(marker, end + 1);
				}
				return calls;
			};

			// Self-check: comment/string noise must NOT be treated as an executable call,
			// while a genuine executable override must still be detected.
			for (const noise of [
				`// test.use({ storageState: { cookies: [], origins: [] } })`,
				`/* test.use({ storageState: { cookies: [], origins: [] } }) */`,
				`const note = 'test.use({ storageState: { cookies: [], origins: [] } })';`
			]) {
				expect(extractTestUseCalls(noise)).toEqual([]);
			}
			expect(
				extractTestUseCalls(`test.use({ storageState: { cookies: [], origins: [] } })`).some(
					(call) => emptyStorageStateOverride.test(call)
				)
			).toBe(true);

			for (const call of extractTestUseCalls(specSource)) {
				expect(call).not.toMatch(emptyStorageStateOverride);
			}

			expect(projectContractsByName.chromium?.testMatch.test(specPath)).toBe(true);
			expect(projectContractsByName['chromium:admin']?.testMatch.test(specPath)).toBe(false);
			expect(projectContractsByName.chromium?.dependencies).toEqual(['setup:user']);
			expect(projectContractsByName.chromium?.use?.storageState).toBe(
				PLAYWRIGHT_STORAGE_STATE.user
			);
		});
	});

	describe('cwd-local Playwright config runtime contract', () => {
		it('rebases the inherited launcher and pins cwd-local web/API ports at runtime', async () => {
			const previousFlapjackUrl = process.env.FLAPJACK_URL;

			await withIsolatedProcessEnv(
				{
					[PLAYWRIGHT_WEB_PORT_ENV]: '5999',
					[PLAYWRIGHT_API_PORT_ENV]: '3999'
				},
				async () => {
					vi.resetModules();
					const { default: cwdLocalConfig } = await import('../../tests/e2e-ui/playwright.config');
					const cwdLocalWebServer = cwdLocalConfig.webServer as PlaywrightWebServerContract;

					expect(cwdLocalConfig.testDir).toBe('..');
					expect(cwdLocalConfig.use?.baseURL).toBe('http://localhost:5183');
					expect(cwdLocalWebServer).toEqual(
						expect.objectContaining({
							command:
								'../../../scripts/playwright_local_stack.sh --force-api-restart --host localhost --port 5183 --strictPort',
							url: 'http://localhost:5183'
						})
					);
					expect(cwdLocalWebServer.env).toEqual(
						expect.objectContaining({
							API_URL: 'http://127.0.0.1:33183',
							API_BASE_URL: 'http://127.0.0.1:33183',
							FJCLOUD_ALLOW_LOOPBACK_SOURCE_ORIGINS: '1',
							LISTEN_ADDR: '127.0.0.1:33183',
							S3_LISTEN_ADDR: '127.0.0.1:33184'
						})
					);
					expect(cwdLocalWebServer.reuseExistingServer).toBe(false);
					expect(cwdLocalWebServer.timeout).toBe(PLAYWRIGHT_WEB_SERVER_TIMEOUT_MS);
					expect(process.env.BASE_URL).toBe('http://localhost:5183');
					expect(process.env.API_URL).toBe('http://127.0.0.1:33183');
					expect(process.env.API_BASE_URL).toBe('http://127.0.0.1:33183');
					expect(process.env.LISTEN_ADDR).toBe('127.0.0.1:33183');
					expect(process.env.S3_LISTEN_ADDR).toBe('127.0.0.1:33184');
				}
			);

			expect(process.env.FLAPJACK_URL).toBe(previousFlapjackUrl);
		}, 15_000);
	});

	describe('formatFixtureSetupFailure diagnostics', () => {
		it('redacts verification tokens and bearer tokens from setup diagnostics', () => {
			const failureMessage = formatFixtureSetupFailure({
				setupName: 'fixture security',
				expectedPath: '/verify-email/{token}',
				currentPath: '/verify-email/abc123?token=secret-token',
				apiUrl: 'http://127.0.0.1:3000',
				adminKey: 'admin-key',
				alertText: 'Bearer sensitive.jwt.token /verify-email/def456?code=code-secret',
				responseUrl: 'http://127.0.0.1:3000/verify-email/ghi789?key=response-secret'
			});
			expect(failureMessage).toContain('/verify-email/[REDACTED]');
			expect(failureMessage).toContain('token=[REDACTED]');
			expect(failureMessage).toContain('code=[REDACTED]');
			expect(failureMessage).toContain('key=[REDACTED]');
			expect(failureMessage).toContain('Bearer [REDACTED]');
			expect(failureMessage).not.toContain('abc123');
			expect(failureMessage).not.toContain('def456');
			expect(failureMessage).not.toContain('ghi789');
			expect(failureMessage).not.toContain('sensitive.jwt.token');
		});
	});

	describe('applyPlaywrightProcessEnvDefaults + resolvePlaywrightRuntime admin key consistency', () => {
		it('sets E2E_ADMIN_KEY to DEFAULT_PLAYWRIGHT_ADMIN_KEY when all env sources are empty so fixtures match the web server', () => {
			// When no .env.local exists and no ADMIN_KEY env var is set,
			// resolvePlaywrightRuntime gives the web server DEFAULT_PLAYWRIGHT_ADMIN_KEY.
			// applyPlaywrightProcessEnvDefaults must set the same value in process.env
			// so that worker fixtures (resolveRequiredFixtureAdminKey) can find it.
			const processEnv = applyEnvDefaults({ processEnv: {}, repoEnv: {}, webEnv: {} });

			expect(processEnv.E2E_ADMIN_KEY).toBe(DEFAULT_PLAYWRIGHT_ADMIN_KEY);

			// Verify the web server runtime uses the same key
			const runtime = resolvePlaywrightRuntime({
				processEnv,
				repoEnv: {},
				webEnv: {},
				fallbackJwtSecret: 'test-jwt-secret'
			});
			expect(runtime.webServerEnv.ADMIN_KEY).toBe(processEnv.E2E_ADMIN_KEY);
		});
	});

	describe('resolveFixtureEnv integration with resolveRequiredFixture* helpers', () => {
		it('applyDefaults → resolveFixtureEnv → resolveRequiredFixtureUserCredentials yields consistent credentials', () => {
			const processEnv = applyEnvDefaults({
				processEnv: {},
				repoEnv: { SEED_USER_EMAIL: 'seed@repo.test' },
				webEnv: { SEED_USER_PASSWORD: 'seed-web-pass' }
			});

			const fixtureEnv = resolveFixtureEnv(processEnv);
			expect(fixtureEnv.userEmail).toBe(processEnv.E2E_USER_EMAIL);
			expect(fixtureEnv.userPassword).toBe(processEnv.E2E_USER_PASSWORD);

			const creds = resolveRequiredFixtureUserCredentials(processEnv);
			expect(creds.email).toBe(fixtureEnv.userEmail);
			expect(creds.password).toBe(fixtureEnv.userPassword);
		});

		it('applyDefaults → resolveFixtureEnv → resolveRequiredFixtureAdminKey yields consistent admin key', () => {
			const processEnv = applyEnvDefaults({
				processEnv: {},
				repoEnv: { ADMIN_KEY: 'repo-admin-key' },
				webEnv: {}
			});

			const fixtureEnv = resolveFixtureEnv(processEnv);
			expect(fixtureEnv.adminKey).toBe(processEnv.E2E_ADMIN_KEY);

			const adminKey = resolveRequiredFixtureAdminKey(processEnv);
			expect(adminKey).toBe(fixtureEnv.adminKey);
		});

		it('integration path matches the fixture wiring: fixtures.ts → auth.setup.ts → admin.auth.setup.ts', () => {
			// Simulate the exact flow: playwright.config.ts calls applyDefaults on process.env,
			// then fixtures.ts calls resolveFixtureEnv(process.env), and auth setup files
			// call resolveRequiredFixture*(process.env) — all three must see consistent state.
			const processEnv = applyEnvDefaults({
				processEnv: {
					E2E_ADMIN_KEY: 'explicit-admin',
					E2E_USER_EMAIL: 'explicit@test.com',
					E2E_USER_PASSWORD: 'explicit-pass'
				},
				repoEnv: {},
				webEnv: {}
			});

			const fixtureEnv = resolveFixtureEnv(processEnv);
			const userCreds = resolveRequiredFixtureUserCredentials(processEnv);
			const adminKey = resolveRequiredFixtureAdminKey(processEnv);

			// All three consumers must agree
			expect(fixtureEnv.adminKey).toBe(adminKey);
			expect(fixtureEnv.userEmail).toBe(userCreds.email);
			expect(fixtureEnv.userPassword).toBe(userCreds.password);

			// And they must reflect the explicit values
			expect(adminKey).toBe('explicit-admin');
			expect(userCreds.email).toBe('explicit@test.com');
			expect(userCreds.password).toBe('explicit-pass');
		});
	});

	// LB-2/LB-3 — opt-in remote-target mode for running browser specs against
	// deployed staging. The loopback guard is the load-bearing safety against
	// credentialed local fixtures pointing at random hosts; relaxing it requires
	// BOTH an explicit env opt-in (PLAYWRIGHT_TARGET_REMOTE=1) AND a hostname
	// match against the staging-only allowlist. If either condition is missing,
	// the original loopback-only behavior must be preserved exactly.
	describe('remote-target opt-in (LB-2/LB-3)', () => {
		it('exports a stable opt-in env var name and a non-empty host suffix allowlist', () => {
			expect(REMOTE_TARGET_OPT_IN_ENV).toBe('PLAYWRIGHT_TARGET_REMOTE');
			expect(Array.isArray(REMOTE_TARGET_HOST_SUFFIX_ALLOWLIST)).toBe(true);
			expect(REMOTE_TARGET_HOST_SUFFIX_ALLOWLIST.length).toBeGreaterThan(0);
			// flapjack.foo is the canonical staging+prod root; tests must not
			// silently broaden this without an explicit edit + review.
			expect(REMOTE_TARGET_HOST_SUFFIX_ALLOWLIST).toContain('.flapjack.foo');
		});

		describe('requireLoopbackHttpUrl with explicit processEnv arg', () => {
			it('still rejects non-loopback URLs when opt-in env is unset (default behavior unchanged)', () => {
				expect(() => requireLoopbackHttpUrl('API_URL', 'https://api.flapjack.foo', {})).toThrow(
					/must use a local loopback host/
				);
			});

			it('still rejects non-loopback URLs when opt-in env is set but host is NOT on the allowlist', () => {
				expect(() =>
					requireLoopbackHttpUrl('API_URL', 'https://api.example.com', {
						PLAYWRIGHT_TARGET_REMOTE: '1'
					})
				).toThrow(/must use a local loopback host/);
			});

			it('rejects non-loopback URLs when host matches allowlist but opt-in env is missing', () => {
				expect(() => requireLoopbackHttpUrl('API_URL', 'https://api.flapjack.foo', {})).toThrow(
					/must use a local loopback host/
				);
			});

			it('rejects opt-in flag values other than the literal "1" to prevent ambiguity', () => {
				for (const truthyButInvalid of ['true', 'yes', 'on', '0', '', 'false']) {
					expect(() =>
						requireLoopbackHttpUrl('API_URL', 'https://api.flapjack.foo', {
							PLAYWRIGHT_TARGET_REMOTE: truthyButInvalid
						})
					).toThrow(/must use a local loopback host/);
				}
			});

			it('accepts an https URL on an allowlisted host suffix when opt-in env is set to "1"', () => {
				expect(
					requireLoopbackHttpUrl('API_URL', 'https://api.flapjack.foo', {
						PLAYWRIGHT_TARGET_REMOTE: '1'
					})
				).toBe('https://api.flapjack.foo');
				expect(
					requireLoopbackHttpUrl('BASE_URL', 'https://cloud.flapjack.foo', {
						PLAYWRIGHT_TARGET_REMOTE: '1'
					})
				).toBe('https://cloud.flapjack.foo');
			});

			it('rejects http (non-https) URLs on allowlisted hosts even when opt-in env is set', () => {
				// Remote-target mode is for credentialed real-staging traffic;
				// unencrypted http to a public host would leak ADMIN_KEY in transit.
				expect(() =>
					requireLoopbackHttpUrl('API_URL', 'http://api.flapjack.foo', {
						PLAYWRIGHT_TARGET_REMOTE: '1'
					})
				).toThrow(/https.*loopback host/);
			});

			it('does not match allowlist suffix as a substring (prevents flapjack.foo.evil.com bypass)', () => {
				expect(() =>
					requireLoopbackHttpUrl('API_URL', 'https://api.flapjack.foo.evil.com', {
						PLAYWRIGHT_TARGET_REMOTE: '1'
					})
				).toThrow(/must use a local loopback host/);
			});
		});

		describe('resolvePlaywrightRuntime with remote-target opt-in', () => {
			it('accepts staging BASE_URL + API_BASE_URL when opt-in is set on processEnv', () => {
				const runtime = resolvePlaywrightRuntime({
					processEnv: {
						BASE_URL: 'https://cloud.flapjack.foo',
						API_BASE_URL: 'https://api.flapjack.foo',
						PLAYWRIGHT_TARGET_REMOTE: '1'
					},
					repoEnv: {},
					webEnv: {},
					fallbackJwtSecret: 'fallback-jwt'
				});

				expect(runtime.baseURL).toBe('https://cloud.flapjack.foo');
				// When BASE_URL is set we already skip spawning the local web server.
				expect(runtime.webServer).toBeUndefined();
				expect(runtime.webServerEnv.FJCLOUD_ALLOW_LOOPBACK_SOURCE_ORIGINS).toBeUndefined();
			});

			it('marks portal auth cookies Secure when BASE_URL is https', () => {
				const portalSpecSource = readFileSync(
					join(process.cwd(), 'tests/e2e-ui/full/billing_portal_payment_method_update.spec.ts'),
					'utf8'
				);
				const remoteBootstrapSource = readFileSync(
					join(process.cwd(), 'tests/fixtures/fresh_signup_remote_bootstrap.ts'),
					'utf8'
				);
				expect(portalSpecSource).toMatch(
					/from\s+['"]\.\.\/\.\.\/fixtures\/fresh_signup_remote_bootstrap['"]/
				);
				expect(portalSpecSource).toMatch(/\bsetAuthCookieForToken\b/);
				expect(remoteBootstrapSource).toMatch(/secure:\s*baseUrlProtocol\s*===\s*'https:'/);
			});

			it('requires billing-portal spec to recover from session-expired redirects on protected-route navigation', () => {
				const portalSpecSource = readFileSync(
					join(process.cwd(), 'tests/e2e-ui/full/billing_portal_payment_method_update.spec.ts'),
					'utf8'
				);
				expect(portalSpecSource).toMatch(/isSessionExpiredUrl/);
				expect(portalSpecSource).toMatch(
					/searchParams\.get\('reason'\)\s*===\s*SESSION_EXPIRED_REASON/
				);
				expect(portalSpecSource).toMatch(/await gotoBillingPageWithSessionRecovery\(/);
				expect(portalSpecSource).toMatch(
					/if\s*\(!isRemoteTargetMode\(\)\)\s*\{\s*throw sessionRecoveryFailure\(/m
				);
				expect(portalSpecSource).toMatch(
					/await page\.goto\('\/console\/billing'\);\s*if\s*\(isSessionExpiredUrl\(page\.url\(\)\)\)\s*\{\s*throw sessionRecoveryFailure\(/m
				);
			});

			it('requires signup-to-paid-invoice spec to recover from session-expired redirects before billing invoices assertions', () => {
				const signupSpecSource = readFileSync(
					join(process.cwd(), 'tests/e2e-ui/full/signup_to_paid_invoice.spec.ts'),
					'utf8'
				);
				expect(signupSpecSource).toMatch(/await gotoWithSessionRecovery\(/);
				expect(signupSpecSource).toMatch(
					/await gotoWithSessionRecovery\(\s*page,\s*'\/console\/billing\/invoices',\s*signup\.email,\s*signup\.password,\s*loginAs\s*\)/
				);
				expect(signupSpecSource).toMatch(
					/if\s*\(!isSessionExpiredUrl\(currentUrl\)\)\s*\{\s*throw error;/m
				);
				expect(signupSpecSource).toMatch(
					/if\s*\(!isRemoteTargetMode\(\)\s*\|\|\s*!loginAs\)\s*\{\s*throw sessionRecoveryFailure\(/m
				);
				expect(signupSpecSource).toMatch(
					/await page\.goto\(path\);\s*if\s*\(isSessionExpiredUrl\(page\.url\(\)\)\)\s*\{\s*throw sessionRecoveryFailure\(/m
				);
			});

			it('staging launcher validates hydrator output instead of eval-ing it directly', () => {
				const launcherSource = readFileSync(
					join(process.cwd(), '../scripts/launch/run_browser_lane_against_staging.sh'),
					'utf8'
				);
				const hydrationHelperSource = readFileSync(
					join(process.cwd(), '../scripts/lib/hydrate_staging_env.sh'),
					'utf8'
				);
				expect(launcherSource).toMatch(/source "\$SCRIPT_DIR\/\.\.\/lib\/hydrate_staging_env\.sh"/);
				expect(launcherSource).toMatch(/\bhydrate_staging_env_from_ssm\b/);
				expect(launcherSource).not.toMatch(/eval\s+"\$\(bash .*hydrate_seeder_env_from_ssm\.sh/);
				expect(hydrationHelperSource).toMatch(/validate_hydrated_export_line\(\)/);
				expect(hydrationHelperSource).toMatch(/hydrate_staging_env_from_ssm\(\)/);
				expect(hydrationHelperSource).not.toMatch(
					/eval\s+"\$\(bash .*hydrate_seeder_env_from_ssm\.sh/
				);
			});

			it('still rejects staging BASE_URL when opt-in env is missing (regression guard)', () => {
				expect(() =>
					resolvePlaywrightRuntime({
						processEnv: { BASE_URL: 'https://cloud.flapjack.foo' },
						repoEnv: {},
						webEnv: {},
						fallbackJwtSecret: 'fallback-jwt'
					})
				).toThrow(/must use a local loopback host/);
			});
		});

		describe('resolveFixtureEnv with remote-target opt-in', () => {
			it('accepts staging API_URL + FLAPJACK_URL when opt-in is set on processEnv', () => {
				const env = resolveFixtureEnv({
					API_URL: 'https://api.flapjack.foo',
					FLAPJACK_URL: 'https://flapjack.flapjack.foo',
					PLAYWRIGHT_TARGET_REMOTE: '1'
				});
				expect(env.apiUrl).toBe('https://api.flapjack.foo');
				expect(env.flapjackUrl).toBe('https://flapjack.flapjack.foo');
			});

			it('still rejects staging API_URL when opt-in env is missing (regression guard)', () => {
				expect(() => resolveFixtureEnv({ API_URL: 'https://api.flapjack.foo' })).toThrow(
					/must use a local loopback host/
				);
			});
		});
	});
});
