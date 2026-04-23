import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
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
	PLAYWRIGHT_DESKTOP_DEVICE,
	DEFAULT_TEST_REGION,
	PLAYWRIGHT_STORAGE_STATE,
	PLAYWRIGHT_PROJECT_CONTRACTS,
	PLAYWRIGHT_WEB_SERVER_COMMAND,
	parseDotenvFile,
	parseDotenvValue,
	resolveFixtureEnv,
	resolveRequiredFixtureAdminKey,
	resolveRequiredFixtureUserCredentials,
	resolvePlaywrightRuntime,
	sanitizeWebServerEnv,
} from '../../playwright.config.contract';

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
				'JWT_SECRET="quoted-secret"',
			].join('\n')
		);

		try {
			expect(parseDotenvFile(envFilePath)).toEqual({
				API_URL: 'http://localhost:3001',
				BASE_URL: 'http://127.0.0.1:4174',
				JWT_SECRET: 'quoted-secret',
			});
		} finally {
			rmSync(tmpPath, { recursive: true, force: true });
		}
	});

	it('sanitizeWebServerEnv removes undefined entries', () => {
		expect(
			sanitizeWebServerEnv({
				API_URL: 'http://localhost:3001',
				BASE_URL: undefined,
			})
		).toEqual({
			API_URL: 'http://localhost:3001',
		});
	});

	it('applyPlaywrightProcessEnvDefaults seeds runner env from .env values and seed defaults', () => {
		const processEnv = applyEnvDefaults({
			processEnv: {},
			repoEnv: {
				SEED_USER_EMAIL: 'repo-seed@example.com',
				DATABASE_URL: 'postgres://repo-user:repo-pass@localhost:5432/fjcloud',
			},
			webEnv: {
				E2E_ADMIN_KEY: 'web-e2e-admin',
				E2E_USER_EMAIL: 'web-e2e@example.com',
				E2E_USER_PASSWORD: 'web-e2e-password',
			},
		});

		expect(processEnv.E2E_ADMIN_KEY).toBe('web-e2e-admin');
		expect(processEnv.E2E_USER_EMAIL).toBe('web-e2e@example.com');
		expect(processEnv.E2E_USER_PASSWORD).toBe('web-e2e-password');
		expect(processEnv.DATABASE_URL).toBe(
			'postgres://repo-user:repo-pass@localhost:5432/fjcloud'
		);
	});

	it('applyPlaywrightProcessEnvDefaults falls back from ADMIN_KEY and seed env when direct E2E_* vars are absent', () => {
		const processEnv = applyEnvDefaults({
			processEnv: {},
			repoEnv: {
				ADMIN_KEY: 'repo-admin',
				SEED_USER_EMAIL: 'repo-seed@example.com',
				DATABASE_URL: 'postgres://repo-user:repo-pass@localhost:5432/fjcloud',
			},
			webEnv: {
				SEED_USER_PASSWORD: 'web-seed-password',
			},
		});

		expect(processEnv.E2E_ADMIN_KEY).toBe('repo-admin');
		expect(processEnv.E2E_USER_EMAIL).toBe('repo-seed@example.com');
		expect(processEnv.E2E_USER_PASSWORD).toBe('web-seed-password');
		expect(processEnv.DATABASE_URL).toBe(
			'postgres://repo-user:repo-pass@localhost:5432/fjcloud'
		);
	});

	it('applyPlaywrightProcessEnvDefaults preserves explicit E2E overrides and uses documented defaults', () => {
		const processEnv = applyEnvDefaults({
			processEnv: {
				E2E_ADMIN_KEY: 'explicit-admin',
				E2E_USER_EMAIL: 'explicit@example.com',
				E2E_USER_PASSWORD: 'explicit-password',
				DATABASE_URL: 'postgres://explicit-user:explicit-pass@localhost:5432/fjcloud',
			},
			repoEnv: {
				ADMIN_KEY: 'repo-admin',
			},
			webEnv: {},
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
			webEnv: {},
		});
		expect(defaultedEnv.E2E_USER_EMAIL).toBe(DEFAULT_E2E_USER_EMAIL);
		expect(defaultedEnv.E2E_USER_PASSWORD).toBe(DEFAULT_E2E_USER_PASSWORD);
		expect(defaultedEnv.E2E_ADMIN_KEY).toBe(DEFAULT_PLAYWRIGHT_ADMIN_KEY);
		expect(defaultedEnv.DATABASE_URL).toBeUndefined();
	});

	it('resolvePlaywrightRuntime disables webServer when BASE_URL is overridden to local rerun URL', () => {
		const runtime = resolvePlaywrightRuntime({
			processEnv: {
				BASE_URL: 'http://127.0.0.1:4174',
				E2E_ADMIN_KEY: 'e2e-key',
			},
			repoEnv: { ADMIN_KEY: 'repo-key' },
			webEnv: { ADMIN_KEY: 'web-key' },
			fallbackJwtSecret: 'fallback-jwt',
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
				fallbackJwtSecret: 'fallback-jwt',
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
				fallbackJwtSecret: 'fallback-jwt',
			})
		).toThrow(
			'API_BASE_URL must use a local loopback host (localhost, 127.0.0.1, or [::1]) for credentialed local browser runs'
		);
	});

	it('resolvePlaywrightRuntime uses default base URL and admin fallback chain without BASE_URL override', () => {
		const runtime = resolvePlaywrightRuntime({
			processEnv: {},
			repoEnv: {},
			webEnv: {},
			fallbackJwtSecret: 'fallback-jwt',
		});

		expect(runtime.baseURL).toBe(DEFAULT_PLAYWRIGHT_BASE_URL);
		expect(runtime.webServer).toEqual({
			command: PLAYWRIGHT_WEB_SERVER_COMMAND,
			env: runtime.webServerEnv,
			url: DEFAULT_PLAYWRIGHT_BASE_URL,
			reuseExistingServer: false,
			timeout: 30_000,
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
					fallbackJwtSecret: 'fallback-jwt',
				}),
				expected: 'web-admin',
			},
			{
				name: 'repo ADMIN_KEY',
				runtime: resolvePlaywrightRuntime({
					processEnv: { ADMIN_KEY: 'process-admin' },
					repoEnv: { ADMIN_KEY: 'repo-admin' },
					webEnv: {},
					fallbackJwtSecret: 'fallback-jwt',
				}),
				expected: 'repo-admin',
			},
			{
				name: 'process ADMIN_KEY',
				runtime: resolvePlaywrightRuntime({
					processEnv: { ADMIN_KEY: 'process-admin' },
					repoEnv: {},
					webEnv: {},
					fallbackJwtSecret: 'fallback-jwt',
				}),
				expected: 'process-admin',
			},
		];

		for (const { name, runtime, expected } of cases) {
			expect(runtime.webServerEnv.ADMIN_KEY, name).toBe(expected);
		}
	});

	it('project contracts preserve narrow-lane wiring for setup and admin/browser projects', () => {
		expect(projectContractsByName['setup:user']?.testMatch).toEqual(/fixtures\/auth\.setup\.ts/);
		expect(projectContractsByName['setup:admin']?.testMatch).toEqual(/fixtures\/admin\.auth\.setup\.ts/);
		expect(projectContractsByName['setup:onboarding']?.testMatch).toEqual(/fixtures\/onboarding\.auth\.setup\.ts/);
		expect(projectContractsByName['setup:customer-journeys']?.testMatch).toEqual(
			/fixtures\/customer-journeys\.auth\.setup\.ts/
		);

		expect(projectContractsByName.chromium?.dependencies).toEqual(['setup:user']);
		expect(projectContractsByName.chromium?.use?.desktopBrowser).toBe('chromium');
		expect(projectContractsByName.chromium?.use?.storageState).toBe(PLAYWRIGHT_STORAGE_STATE.user);

		expect(projectContractsByName['chromium:onboarding']?.dependencies).toEqual(['setup:onboarding']);
		expect(projectContractsByName['chromium:onboarding']?.use?.desktopBrowser).toBe('chromium');
		expect(projectContractsByName['chromium:onboarding']?.use?.storageState).toBe(
			PLAYWRIGHT_STORAGE_STATE.onboarding
		);
		expect(projectContractsByName['chromium:customer-journeys']?.dependencies).toEqual([
			'setup:customer-journeys'
		]);
		expect(projectContractsByName['chromium:customer-journeys']?.use?.desktopBrowser).toBe('chromium');
		expect(projectContractsByName['chromium:customer-journeys']?.use?.storageState).toBe(
			PLAYWRIGHT_STORAGE_STATE.customerJourneys
		);

		expect(projectContractsByName['chromium:admin']?.dependencies).toEqual(['setup:admin']);
		expect(projectContractsByName['chromium:admin']?.use?.desktopBrowser).toBe('chromium');
		expect(projectContractsByName['chromium:admin']?.use?.storageState).toBe(PLAYWRIGHT_STORAGE_STATE.admin);

		expect(PLAYWRIGHT_DESKTOP_DEVICE.firefox).toBe('Desktop Firefox');
		expect(PLAYWRIGHT_DESKTOP_DEVICE.webkit).toBe('Desktop Safari');

		expect(projectContractsByName['firefox:public']?.use?.desktopBrowser).toBe('firefox');
		expect(projectContractsByName['firefox:smoke']?.dependencies).toEqual(['setup:user']);
		expect(projectContractsByName['firefox:smoke']?.use?.storageState).toBe(PLAYWRIGHT_STORAGE_STATE.user);

		expect(projectContractsByName['webkit:public']?.use?.desktopBrowser).toBe('webkit');
		expect(projectContractsByName['webkit:smoke']?.dependencies).toEqual(['setup:user']);
		expect(projectContractsByName['webkit:smoke']?.use?.storageState).toBe(PLAYWRIGHT_STORAGE_STATE.user);
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
				flapjackUrl: DEFAULT_FLAPJACK_URL,
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
				FLAPJACK_URL: 'http://127.0.0.1:7700',
			});
			expect(env).toEqual({
				apiUrl: 'http://localhost:3001',
				adminKey: 'admin-key',
				userEmail: 'e2e@test.com',
				userPassword: 'pass',
				testRegion: 'ap-south-1',
				flapjackUrl: 'http://127.0.0.1:7700',
			});
		});
	});

	describe('required fixture auth env helpers', () => {
		it('resolves required user credentials from fixture env', () => {
			expect(
				resolveRequiredFixtureUserCredentials({
					E2E_USER_EMAIL: 'user@test.com',
					E2E_USER_PASSWORD: 'secret123',
				})
			).toEqual({
				email: 'user@test.com',
				password: 'secret123',
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
					E2E_USER_PASSWORD: 'secret123',
				})
			).toThrow(
				'E2E_USER_EMAIL and E2E_USER_PASSWORD must be set to run browser-unmocked tests'
			);
		});

		it('rejects whitespace-only user password', () => {
			expect(() =>
				resolveRequiredFixtureUserCredentials({
					E2E_USER_EMAIL: 'user@test.com',
					E2E_USER_PASSWORD: '   ',
				})
			).toThrow(
				'E2E_USER_EMAIL and E2E_USER_PASSWORD must be set to run browser-unmocked tests'
			);
		});

		it('trims user email but preserves the exact password value', () => {
			expect(
				resolveRequiredFixtureUserCredentials({
					E2E_USER_EMAIL: '  user@test.com  ',
					E2E_USER_PASSWORD: '  secret123  ',
				})
			).toEqual({
				email: 'user@test.com',
				password: '  secret123  ',
			});
		});

		it('resolves required admin key from fixture env', () => {
			expect(
				resolveRequiredFixtureAdminKey({
					E2E_ADMIN_KEY: 'admin-key',
				})
			).toBe('admin-key');
		});

		it('falls back to ADMIN_KEY when E2E_ADMIN_KEY is unset', () => {
			expect(
				resolveRequiredFixtureAdminKey({
					ADMIN_KEY: 'server-admin-key',
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
					E2E_ADMIN_KEY: '  \t\n  ',
				})
			).toThrow(
				'E2E_ADMIN_KEY must be set to run admin browser-unmocked tests'
			);
		});

		it('preserves the exact admin key value', () => {
			expect(
				resolveRequiredFixtureAdminKey({
					E2E_ADMIN_KEY: '  admin-key  ',
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
						webEnv: { E2E_ADMIN_KEY: 'pos2', ADMIN_KEY: 'pos4' },
					},
					expected: 'pos1',
				},
				{
					label: 'position 2 wins',
					input: {
						processEnv: { ADMIN_KEY: 'pos6' },
						repoEnv: { E2E_ADMIN_KEY: 'pos3', ADMIN_KEY: 'pos5' },
						webEnv: { E2E_ADMIN_KEY: 'pos2', ADMIN_KEY: 'pos4' },
					},
					expected: 'pos2',
				},
				{
					label: 'position 3 wins',
					input: {
						processEnv: { ADMIN_KEY: 'pos6' },
						repoEnv: { E2E_ADMIN_KEY: 'pos3', ADMIN_KEY: 'pos5' },
						webEnv: { ADMIN_KEY: 'pos4' },
					},
					expected: 'pos3',
				},
				{
					label: 'position 4 wins',
					input: {
						processEnv: { ADMIN_KEY: 'pos6' },
						repoEnv: { ADMIN_KEY: 'pos5' },
						webEnv: { ADMIN_KEY: 'pos4' },
					},
					expected: 'pos4',
				},
				{
					label: 'position 5 wins',
					input: {
						processEnv: { ADMIN_KEY: 'pos6' },
						repoEnv: { ADMIN_KEY: 'pos5' },
						webEnv: {},
					},
					expected: 'pos5',
				},
				{
					label: 'position 6 wins',
					input: {
						processEnv: { ADMIN_KEY: 'pos6' },
						repoEnv: {},
						webEnv: {},
					},
					expected: 'pos6',
				},
				{
					label: 'position 7 wins',
					input: {
						processEnv: {},
						repoEnv: {},
						webEnv: {},
					},
					expected: DEFAULT_PLAYWRIGHT_ADMIN_KEY,
				},
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
						webEnv: { E2E_USER_EMAIL: 'pos2', SEED_USER_EMAIL: 'pos6' },
					},
					expected: 'pos1',
				},
				{
					label: 'position 4 wins',
					input: {
						processEnv: { SEED_USER_EMAIL: 'pos4' },
						repoEnv: { SEED_USER_EMAIL: 'pos5' },
						webEnv: { SEED_USER_EMAIL: 'pos6' },
					},
					expected: 'pos4',
				},
				{
					label: 'position 5 wins',
					input: {
						processEnv: {},
						repoEnv: { SEED_USER_EMAIL: 'pos5' },
						webEnv: { SEED_USER_EMAIL: 'pos6' },
					},
					expected: 'pos5',
				},
				{
					label: 'position 6 wins',
					input: {
						processEnv: {},
						repoEnv: {},
						webEnv: { SEED_USER_EMAIL: 'pos6' },
					},
					expected: 'pos6',
				},
				{
					label: 'position 7 wins',
					input: {
						processEnv: {},
						repoEnv: {},
						webEnv: {},
					},
					expected: DEFAULT_E2E_USER_EMAIL,
				},
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
				'tests/e2e-ui/full/admin/some-future-admin.spec.ts',
			];
			for (const specPath of adminSpecs) {
				expect(projectContractsByName.chromium?.testMatch.test(specPath)).toBe(false);
			}
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
				fallbackJwtSecret: 'test-jwt-secret',
			});
			expect(runtime.webServerEnv.ADMIN_KEY).toBe(processEnv.E2E_ADMIN_KEY);
		});
	});

	describe('resolveFixtureEnv integration with resolveRequiredFixture* helpers', () => {
		it('applyDefaults → resolveFixtureEnv → resolveRequiredFixtureUserCredentials yields consistent credentials', () => {
			const processEnv = applyEnvDefaults({
				processEnv: {},
				repoEnv: { SEED_USER_EMAIL: 'seed@repo.test' },
				webEnv: { SEED_USER_PASSWORD: 'seed-web-pass' },
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
				webEnv: {},
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
					E2E_USER_PASSWORD: 'explicit-pass',
				},
				repoEnv: {},
				webEnv: {},
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
});
