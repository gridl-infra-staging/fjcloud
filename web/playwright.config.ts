import { randomBytes } from 'node:crypto';
import { resolve } from 'node:path';
import { defineConfig, devices, type PlaywrightTestProject } from '@playwright/test';
import {
	applyPlaywrightProcessEnvDefaults,
	PLAYWRIGHT_DESKTOP_DEVICE,
	PLAYWRIGHT_PROJECT_CONTRACTS,
	parseDotenvFile,
	resolvePlaywrightRuntime,
	type PlaywrightProjectContract,
} from './playwright.config.contract';

/**
 * Browser (unmocked) test configuration.
 *
 * Requires a fully running stack:
 *   - SvelteKit dev server  (BASE_URL,  default http://localhost:5173)
 *   - Rust API              (API_URL,   default http://localhost:3001)
 *   - Postgres with migrations applied
 *
 * Auth credentials for the test user account must be supplied via env:
 *   E2E_USER_EMAIL, E2E_USER_PASSWORD
 *
 * Admin credentials:
 *   E2E_ADMIN_KEY
 *
 * Optional:
 *   E2E_TEST_REGION  — region with a running VM for index creation tests
 *                      (default: us-east-1)
 */
const repoEnv = parseDotenvFile(resolve(process.cwd(), '..', '.env.local'));
const webEnv = parseDotenvFile(resolve(process.cwd(), '.env.local'));
// Worker fixtures and auth setup files read process.env directly, so the
// runner must materialize the full fallback chain here before Playwright forks:
// process.env.E2E_ADMIN_KEY ?? webEnv.E2E_ADMIN_KEY ?? repoEnv.E2E_ADMIN_KEY ??
// webEnv.ADMIN_KEY ?? repoEnv.ADMIN_KEY ?? process.env.ADMIN_KEY
// process.env.E2E_USER_EMAIL ?? webEnv.E2E_USER_EMAIL ?? repoEnv.E2E_USER_EMAIL ??
// process.env.SEED_USER_EMAIL ?? repoEnv.SEED_USER_EMAIL ?? webEnv.SEED_USER_EMAIL ??
// 'dev@example.com'
// process.env.E2E_USER_PASSWORD ?? webEnv.E2E_USER_PASSWORD ?? repoEnv.E2E_USER_PASSWORD ??
// process.env.SEED_USER_PASSWORD ?? repoEnv.SEED_USER_PASSWORD ?? webEnv.SEED_USER_PASSWORD ??
// 'localdev-password-1234'
applyPlaywrightProcessEnvDefaults({
	processEnv: process.env,
	repoEnv,
	webEnv,
});
const fallbackJwtSecret = randomBytes(32).toString('hex');
const runtimeContract = resolvePlaywrightRuntime({
	processEnv: process.env,
	repoEnv,
	webEnv,
	fallbackJwtSecret,
});

/** Map a contract-defined project shape to a Playwright-native project config,
 * applying desktop device emulation, storage-state routing, and trace/screenshot
 * overrides from the contract without introducing any env or default logic here. */
function toPlaywrightProject(project: PlaywrightProjectContract): PlaywrightTestProject {
	const use: Record<string, unknown> = {};
	if (project.use?.desktopBrowser) {
		Object.assign(use, devices[PLAYWRIGHT_DESKTOP_DEVICE[project.use.desktopBrowser]]);
	}
	if (project.use?.storageState) {
		use.storageState = project.use.storageState;
	}
	if (project.use?.trace) {
		use.trace = project.use.trace;
	}
	if (project.use?.screenshot) {
		use.screenshot = project.use.screenshot;
	}

	return {
		name: project.name,
		testMatch: project.testMatch,
		...(project.dependencies ? { dependencies: project.dependencies } : {}),
		...(Object.keys(use).length > 0 ? { use } : {}),
	};
}

export default defineConfig({
	testDir: './tests',
	fullyParallel: false,
	forbidOnly: !!process.env.CI,
	retries: process.env.CI ? 1 : 0,
	workers: 1,
	reporter: process.env.CI ? 'github' : [['html', { open: 'never' }]],

	use: {
		baseURL: runtimeContract.baseURL,
		trace: 'on-first-retry',
		screenshot: 'only-on-failure',
	},

	projects: PLAYWRIGHT_PROJECT_CONTRACTS.map(toPlaywrightProject),

	// Optionally start the web server. With reuseExistingServer the dev server
	// must already be running (the Rust API cannot be started from here).
	webServer: runtimeContract.webServer,
});
