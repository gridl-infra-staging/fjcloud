import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { describe, expect, it } from 'vitest';
import {
	applyPlaywrightProcessEnvDefaults,
	DEFAULT_API_URL,
	DEFAULT_E2E_USER_EMAIL,
	DEFAULT_E2E_USER_PASSWORD,
	DEFAULT_FLAPJACK_URL,
	DEFAULT_PLAYWRIGHT_ADMIN_KEY,
	DEFAULT_PLAYWRIGHT_BASE_URL,
	DEFAULT_TEST_REGION,
	PLAYWRIGHT_STORAGE_STATE,
	PLAYWRIGHT_PROJECT_CONTRACTS,
	PLAYWRIGHT_WEB_SERVER_COMMAND,
	parseDotenvFile,
	parseDotenvValue,
	REMOTE_TARGET_OPT_IN_ENV,
	REMOTE_TARGET_HOST_SUFFIX_ALLOWLIST,
	requireLoopbackHttpUrl,
	resolveFixtureEnv,
	resolveRequiredFixtureAdminKey,
	resolveRequiredFixtureUserCredentials,
	resolvePlaywrightRuntime,
	sanitizeWebServerEnv
} from '../../playwright.config.contract';
import { formatFixtureSetupFailure } from '../../tests/fixtures/fixtures';

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

function applyEnvDefaults(input: EnvDefaultsInput): MutableEnv {
	applyPlaywrightProcessEnvDefaults(input);
	return input.processEnv;
}

describe('playwright config contract', () => {
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

	it('applyPlaywrightProcessEnvDefaults propagates Mailpit and Stripe webhook env for fixture-owned billing lanes', () => {
		const processEnv = applyEnvDefaults({
			processEnv: {},
			repoEnv: {
				MAILPIT_API_URL: 'http://localhost:8025',
				STRIPE_WEBHOOK_SECRET: 'whsec_repo'
			},
			webEnv: {
				STRIPE_WEBHOOK_SECRET: 'whsec_web'
			}
		});

		expect(processEnv.MAILPIT_API_URL).toBe('http://localhost:8025');
		expect(processEnv.STRIPE_WEBHOOK_SECRET).toBe('whsec_web');
	});

	it('applyPlaywrightProcessEnvDefaults preserves explicit shell overrides for Mailpit and Stripe webhook env', () => {
		const processEnv = applyEnvDefaults({
			processEnv: {
				MAILPIT_API_URL: 'http://127.0.0.1:18025',
				STRIPE_WEBHOOK_SECRET: 'whsec_process'
			},
			repoEnv: {
				MAILPIT_API_URL: 'http://localhost:8025',
				STRIPE_WEBHOOK_SECRET: 'whsec_repo'
			},
			webEnv: {
				MAILPIT_API_URL: 'http://localhost:28025',
				STRIPE_WEBHOOK_SECRET: 'whsec_web'
			}
		});

		expect(processEnv.MAILPIT_API_URL).toBe('http://127.0.0.1:18025');
		expect(processEnv.STRIPE_WEBHOOK_SECRET).toBe('whsec_process');
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

	it('resolvePlaywrightRuntime rejects non-loopback API_BASE_URL overrides for the spawned web server', () => {
		expect(() =>
			resolvePlaywrightRuntime({
				processEnv: {},
				repoEnv: { API_BASE_URL: 'https://api.example.com' },
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

	it('resolvePlaywrightRuntime uses default base URL and admin fallback chain without BASE_URL override', () => {
		const runtime = resolvePlaywrightRuntime({
			processEnv: {},
			repoEnv: {},
			webEnv: {},
			fallbackJwtSecret: 'fallback-jwt'
		});

		expect(runtime.baseURL).toBe(DEFAULT_PLAYWRIGHT_BASE_URL);
		expect(runtime.webServer).toEqual({
			command: PLAYWRIGHT_WEB_SERVER_COMMAND,
			env: runtime.webServerEnv,
			url: DEFAULT_PLAYWRIGHT_BASE_URL,
			reuseExistingServer: false,
			timeout: 30_000
		});
		expect(runtime.webServerEnv.ADMIN_KEY).toBe(DEFAULT_PLAYWRIGHT_ADMIN_KEY);
		expect(runtime.webServerEnv.API_BASE_URL).toBe(DEFAULT_API_URL);
		expect(runtime.webServerEnv.JWT_SECRET).toBe('fallback-jwt');
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
		it('auth.spec.ts matches the chromium project (setup:user dependency)', () => {
			const specPath = 'tests/e2e-ui/full/auth.spec.ts';
			expect(projectContractsByName.chromium?.testMatch.test(specPath)).toBe(true);
			expect(projectContractsByName['chromium:admin']?.testMatch.test(specPath)).toBe(false);
			expect(projectContractsByName.chromium?.dependencies).toEqual(['setup:user']);
		});

		it('settings.spec.ts matches the chromium project (setup:user dependency)', () => {
			const specPath = 'tests/e2e-ui/full/settings.spec.ts';
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

		it('signup_to_paid_invoice.spec.ts does not mask billing/verification failures as skips', () => {
			const signupSpecSource = readFileSync(
				join(process.cwd(), 'tests/e2e-ui/full/signup_to_paid_invoice.spec.ts'),
				'utf8'
			);
			expect(signupSpecSource).not.toMatch(
				/catch\s*\(\s*error\s*\)\s*\{[\s\S]*test\.skip\(true,\s*`Signup paid-invoice preconditions unavailable:/
			);
		});
	});

		describe('Stage 6 signup fixture cleanup wiring', () => {
		it('arrangePaidInvoiceForFreshSignup fixture threads _trackCustomerForCleanup', () => {
			const fixtureSource = readFileSync(join(process.cwd(), 'tests/fixtures/fixtures.ts'), 'utf8');
			expect(fixtureSource).toMatch(
				/arrangePaidInvoiceForFreshSignup:\s*async\s*\(\{\s*_trackCustomerForCleanup\s*\},\s*use\)\s*=>\s*\{[\s\S]*arrangePaidInvoiceForFreshSignup\(\{\s*email,\s*password,\s*trackCustomerForCleanup:\s*_trackCustomerForCleanup/
			);
		});

		it('arrangePaidInvoiceForFreshSignup contract remains paid-invoice-only', () => {
			const fixtureSource = readFileSync(join(process.cwd(), 'tests/fixtures/fixtures.ts'), 'utf8');
			expect(fixtureSource).toMatch(
				/type\s+ArrangePaidInvoiceForFreshSignupResult\s*=\s*\{[\s\S]*customerId:\s*string;[\s\S]*invoiceId:\s*string;[\s\S]*billingMonth:\s*string;[\s\S]*\}/
			);
			expect(fixtureSource).not.toMatch(/\binvoiceEmailDelivered\b/);
			expect(fixtureSource).not.toMatch(/\binvoiceEmailMessageId\b/);
			expect(fixtureSource).not.toMatch(/\bdunningSubscriptionStatus\b/);
			expect(fixtureSource).not.toMatch(/\brefundedInvoiceId\b/);
		});

		it('does not wire removed subscription-oriented fixtures in test.extend', () => {
			const fixtureSource = readFileSync(join(process.cwd(), 'tests/fixtures/fixtures.ts'), 'utf8');
			expect(fixtureSource).not.toMatch(/\barrangeBillingDunningForFreshSignup:\s*async\b/);
			expect(fixtureSource).not.toMatch(/\barrangeRefundedInvoiceForFreshSignup:\s*async\b/);
		});

		it('slims arrangeBillingPortalCustomer result contract to required billing-portal data only', () => {
			const fixtureSource = readFileSync(join(process.cwd(), 'tests/fixtures/fixtures.ts'), 'utf8');
			const resultContractMatch = fixtureSource.match(
				/type\s+ArrangeBillingPortalCustomerResult\s*=\s*CreatedFixtureUser\s*&\s*\{[\s\S]*?\n\};/
			);
			expect(resultContractMatch).not.toBeNull();
			const resultContractBlock = resultContractMatch![0];
			expect(resultContractBlock).not.toMatch(/\bsubscriptionCurrentPeriodEnd\b/);
			expect(resultContractBlock).not.toMatch(/\bsubscription:\s*SubscriptionResponse\b/);
			expect(resultContractBlock).not.toMatch(/\bcancelAtPeriodEnd\b/);
			expect(resultContractBlock).toMatch(/\bstripeCustomerId:\s*string;/);
			expect(resultContractBlock).toMatch(/\bdefaultPaymentMethodId:\s*string;/);
		});

			it('routes fallback verification lookup through findVerificationTokenViaStagingSsm only', () => {
				const fixtureSource = readFileSync(join(process.cwd(), 'tests/fixtures/fixtures.ts'), 'utf8');
				expect(fixtureSource).toMatch(
					/import\s*\{\s*findVerificationTokenViaStagingSsm\s*\}\s*from\s*['"]\.\/staging_db_lookup['"]/
				);
				expect(fixtureSource).toMatch(/return\s+findVerificationTokenViaStagingSsm\(email\)/);
				expect(fixtureSource).not.toMatch(/SELECT\s+email_verify_token/i);
				expect(fixtureSource).not.toMatch(/\bpsql\s*"\$DATABASE_URL"/);
				expect(fixtureSource).not.toMatch(/\bspawnSync\b/);
			});

			it('URL-encodes Mailpit search queries before calling the API', () => {
				const fixtureSource = readFileSync(join(process.cwd(), 'tests/fixtures/fixtures.ts'), 'utf8');
				expect(fixtureSource).toMatch(
					/\/api\/v1\/search\?query=\$\{encodeURIComponent\(query\)\}/
				);
			});

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
				expect(() =>
					requireLoopbackHttpUrl('API_URL', 'https://api.flapjack.foo', {})
				).toThrow(/must use a local loopback host/);
			});

			it('still rejects non-loopback URLs when opt-in env is set but host is NOT on the allowlist', () => {
				expect(() =>
					requireLoopbackHttpUrl('API_URL', 'https://api.example.com', {
						PLAYWRIGHT_TARGET_REMOTE: '1'
					})
				).toThrow(/must use a local loopback host/);
			});

			it('rejects non-loopback URLs when host matches allowlist but opt-in env is missing', () => {
				expect(() =>
					requireLoopbackHttpUrl('API_URL', 'https://api.flapjack.foo', {})
				).toThrow(/must use a local loopback host/);
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
			});

			it('marks portal auth cookies Secure when BASE_URL is https', () => {
				const portalSpecSource = readFileSync(
					join(process.cwd(), 'tests/e2e-ui/full/billing_portal_payment_method_update.spec.ts'),
					'utf8'
				);
				expect(portalSpecSource).toMatch(/secure:\s*BASE_URL_PROTOCOL\s*===\s*'https:'/);
			});

			it('staging launcher validates hydrator output instead of eval-ing it directly', () => {
				const launcherSource = readFileSync(
					join(process.cwd(), '../scripts/launch/run_browser_lane_against_staging.sh'),
					'utf8'
				);
				expect(launcherSource).toMatch(/validate_hydrated_export_line\(\)/);
				expect(launcherSource).toMatch(/hydrate_staging_env_from_ssm\(\)/);
				expect(launcherSource).not.toMatch(
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
				expect(() =>
					resolveFixtureEnv({ API_URL: 'https://api.flapjack.foo' })
				).toThrow(/must use a local loopback host/);
			});
		});
	});
});
