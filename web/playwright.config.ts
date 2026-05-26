import { randomBytes } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig, devices, type PlaywrightTestProject } from '@playwright/test';
import {
	applyPlaywrightProcessEnvDefaults,
	PLAYWRIGHT_DESKTOP_DEVICE,
	PLAYWRIGHT_PROJECT_CONTRACTS,
	parseDotenvFile,
	resolveDefaultPlaywrightWebPort,
	resolvePlaywrightRuntime,
	type PlaywrightProjectContract
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
const configDir = dirname(fileURLToPath(import.meta.url));
const repoEnv = parseDotenvFile(resolve(configDir, '..', '.env.local'));
const webEnv = parseDotenvFile(resolve(configDir, '.env.local'));

function applyWorkspaceScopedApiDefaults(processEnv: Record<string, string | undefined>): void {
	const hasApiBaseUrl = Boolean(processEnv.API_BASE_URL?.trim());
	const hasApiUrl = Boolean(processEnv.API_URL?.trim());
	const hasListenAddr = Boolean(processEnv.LISTEN_ADDR?.trim());
	const hasS3ListenAddr = Boolean(processEnv.S3_LISTEN_ADDR?.trim());
	if (hasApiBaseUrl && hasApiUrl && hasListenAddr && hasS3ListenAddr) {
		return;
	}

	const workspaceWebPort = resolveDefaultPlaywrightWebPort(process.cwd());
	const workspaceApiPort = workspaceWebPort + 1000;
	const workspaceApiBaseUrl = `http://127.0.0.1:${workspaceApiPort}`;
	if (!hasApiBaseUrl) {
		processEnv.API_BASE_URL = workspaceApiBaseUrl;
	}
	if (!hasApiUrl) {
		processEnv.API_URL = workspaceApiBaseUrl;
	}
	if (!hasListenAddr) {
		processEnv.LISTEN_ADDR = `127.0.0.1:${workspaceApiPort}`;
	}
	if (!hasS3ListenAddr) {
		processEnv.S3_LISTEN_ADDR = `127.0.0.1:${workspaceApiPort + 1}`;
	}
}
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
	webEnv
});
applyWorkspaceScopedApiDefaults(process.env);
const fallbackJwtSecret = randomBytes(32).toString('hex');
const runtimeContract = resolvePlaywrightRuntime({
	processEnv: process.env,
	repoEnv,
	webEnv,
	fallbackJwtSecret,
	argv: process.argv.slice(2)
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
		...(Object.keys(use).length > 0 ? { use } : {})
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
		screenshot: 'only-on-failure'
	},

	projects: PLAYWRIGHT_PROJECT_CONTRACTS.map(toPlaywrightProject),

	// Optionally start the web server. With reuseExistingServer the dev server
	// must already be running (the Rust API cannot be started from here).
	webServer: runtimeContract.webServer
});
