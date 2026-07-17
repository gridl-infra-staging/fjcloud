# Owner Snapshot

```text
/**
 * @module Stub summary for playwright.config.ts.
 */
import { randomBytes } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig, devices, type PlaywrightTestProject } from '@playwright/test';
import {
	applyPlaywrightProcessEnvDefaults,
	resolveDefaultPlaywrightWebPort,
	resolveDefaultPlaywrightApiPort,
	PLAYWRIGHT_WEB_PORT_ENV,
	PLAYWRIGHT_DESKTOP_DEVICE,
	PLAYWRIGHT_PROJECT_CONTRACTS,
	parseDotenvFile,
	resolvePlaywrightRuntime,
	selectPlaywrightSecretEnv,
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
const repoEnvPaths = [
	resolve(configDir, '..', '.env.local.pre-signoff-backup'),
	resolve(configDir, '..', '.env.local.bak-codex'),
	resolve(configDir, '..', '.env.local')
];
const secretEnvPath = process.env.FJCLOUD_SECRET_FILE
	? resolve(process.env.FJCLOUD_SECRET_FILE)
	: resolve(configDir, '..', '.secret', '.env.secret');
const webEnvPaths = [resolve(configDir, '.env.local')];

function loadLayeredDotenv(paths: readonly string[]): Record<string, string> {
	return paths.reduce<Record<string, string>>(
		(env, path) => ({ ...env, ...parseDotenvFile(path) }),
		{}
	);
}

const repoEnv = {
	...loadLayeredDotenv(repoEnvPaths),
	...selectPlaywrightSecretEnv(parseDotenvFile(secretEnvPath))
};
const webEnv = loadLayeredDotenv(webEnvPaths);

/**
 * TODO: Document applyWorkspaceScopedApiDefaults.
 */
function applyWorkspaceScopedApiDefaults(processEnv: Record<string, string | undefined>): void {
	const hasWebPort = Boolean(processEnv[PLAYWRIGHT_WEB_PORT_ENV]?.trim());
	const hasApiBaseUrl = Boolean(processEnv.API_BASE_URL?.trim());
	const hasApiUrl = Boolean(processEnv.API_URL?.trim());
	const hasListenAddr = Boolean(processEnv.LISTEN_ADDR?.trim());
	const hasS3ListenAddr = Boolean(processEnv.S3_LISTEN_ADDR?.trim());
	if (hasWebPort && hasApiBaseUrl && hasApiUrl && hasListenAddr && hasS3ListenAddr) {
		return;
	}

	const workspaceWebPort = resolveDefaultPlaywrightWebPort(process.cwd());
	if (!hasWebPort) {
		processEnv[PLAYWRIGHT_WEB_PORT_ENV] = String(workspaceWebPort);
	}
	const workspaceApiPort = resolveDefaultPlaywrightApiPort(process.cwd());
	const workspaceApiBaseUrl = `http://localhost:${workspaceApiPort}`;
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
// process.env.E2E_ADMIN_KEY ?? (local-only: webEnv.E2E_ADMIN_KEY ?? repoEnv.E2E_ADMIN_KEY ??)
// (local-only: webEnv.ADMIN_KEY ?? repoEnv.ADMIN_KEY ?? process.env.ADMIN_KEY)
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
/**
 * @module Stub summary for web/playwright.config.contract.ts.
 */
import { randomUUID } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { requireNonBlankString, requireNonEmptyString } from './tests/fixtures/contract-guards';

export const DEFAULT_PLAYWRIGHT_BASE_URL = 'http://localhost:5173';
export const DEFAULT_PLAYWRIGHT_ADMIN_KEY = `playwright-local-admin-${randomUUID()}`;
export const PLAYWRIGHT_WEB_SERVER_COMMAND =
	'../scripts/playwright_local_stack.sh --force-api-restart';
export const PLAYWRIGHT_WEB_ONLY_SERVER_COMMAND = '../scripts/web-dev.sh';
export const PLAYWRIGHT_WEB_PORT_ENV = 'PLAYWRIGHT_WEB_PORT';
export const PLAYWRIGHT_API_PORT_ENV = 'PLAYWRIGHT_API_PORT';
// Flapjack listens on a workspace-derived port (see resolveDefaultPlaywrightFlapjackPort)
// so parallel worktrees do not collide on a single shared flapjack instance. Before
// 2026-05-26 the flapjack URL was hardcoded to DEFAULT_FLAPJACK_URL (:7700) for every
// workspace; concurrent worktrees then reused each other's flapjack — whose in-memory
// node admin key did not match — and every proxied index op (settings/browse/rules/
// synonyms/…) failed flapjack auth with HTTP 403 "Invalid Application-ID or API key".
export const PLAYWRIGHT_FLAPJACK_PORT_ENV = 'PLAYWRIGHT_FLAPJACK_PORT';
export const PLAYWRIGHT_STORAGE_STATE = {
	user: 'tests/fixtures/.auth/user.json',
	onboarding: 'tests/fixtures/.auth/onboarding.json',
	customerJourneys: 'tests/fixtures/.auth/customer-journeys.json',
	admin: 'tests/fixtures/.auth/admin.json'
} as const;
export const PLAYWRIGHT_WEB_SERVER_TIMEOUT_MS = 180_000;
// Firefox/WebKit dropped 2026-05-02. Playwright-on-Linux WebKit isn't real
// Safari (no ITP, no Apple Pay, no Stripe 3DS quirks), and Firefox is
// ~3-6% of users — neither earns its CI cycle cost at paid-beta scale.
// Real Safari smoke is operator-driven on macOS pre-launch.
export const PLAYWRIGHT_DESKTOP_DEVICE = {
	chromium: 'Desktop Chrome'
} as const;
export type PlaywrightDesktopBrowser = keyof typeof PLAYWRIGHT_DESKTOP_DEVICE;

// Fixture-side env defaults — single source of truth for values previously
// scattered across fixtures.ts, searchable-index.ts, auth.setup.ts, etc.
export const DEFAULT_FLAPJACK_URL = 'http://localhost:7700';
export const DEFAULT_TEST_REGION = 'us-east-1';
export const DEFAULT_E2E_USER_EMAIL = 'dev@example.com';
export const DEFAULT_E2E_USER_PASSWORD = 'localdev-password-1234';

export type PlaywrightProjectContract = {
	name: string;
	testMatch: RegExp;
	dependencies?: string[];
	use?: {
		desktopBrowser?: PlaywrightDesktopBrowser;
		storageState?: string;
		trace?: 'off' | 'on-first-retry';
		screenshot?: 'off' | 'only-on-failure';
	};
};

export type ResolvePlaywrightRuntimeParams = {
	processEnv: Record<string, string | undefined>;
	repoEnv: Record<string, string>;
	webEnv: Record<string, string>;
	fallbackJwtSecret: string;
	argv?: string[];
	workspacePath?: string;
};

export type ApplyPlaywrightProcessEnvDefaultsParams = Omit<
	ResolvePlaywrightRuntimeParams,
	'fallbackJwtSecret'
>;

export type PlaywrightWebServerContract = {
	command: string;
	env: Record<string, string>;
	url: string;
	reuseExistingServer: boolean;
	timeout: number;
};

export type PlaywrightRuntimeContract = {
	baseURL: string;
	webServerEnv: Record<string, string>;
	webServer: PlaywrightWebServerContract | undefined;
};

/**
 * TODO: Document isPublicOnlyPlaywrightSelection.
 */
function isPublicOnlyPlaywrightSelection(argv: string[]): boolean {
	let hasPublicProjectSelection = false;
	for (let index = 0; index < argv.length; index += 1) {
		const arg = argv[index];
		if (arg === '--project' && argv[index + 1] === 'chromium:public') {
			hasPublicProjectSelection = true;
			continue;
		}
		if (arg.startsWith('--project=') && arg.slice('--project='.length) === 'chromium:public') {
			hasPublicProjectSelection = true;
		}
	}

	if (!hasPublicProjectSelection) {
		return false;
	}

	const specFilters = argv.filter((arg) => arg.includes('.spec.ts'));
	if (specFilters.length === 0) {
		return true;
	}

	return specFilters.every((filterArg) => filterArg.includes('public-'));
}

const PLAYWRIGHT_DEFAULT_PORT_HASH_MIN = 5600;
const PLAYWRIGHT_DEFAULT_PORT_HASH_SPAN = 2000;
const PLAYWRIGHT_DEFAULT_API_PORT_HASH_MIN = 7600;
// Flapjack band sits above web (5600–7599), API (7600–9599), and the API's S3 sidecar
// (apiPort+1, ≤9600) so the three workspace-derived ports — which all share the same
// hash offset — never collide. 9700 + offset(0–1999) → 9700–11699, safely below 65535.
const PLAYWRIGHT_DEFAULT_FLAPJACK_PORT_HASH_MIN = 9700;
const LOOPBACK_HTTP_HOST = 'localhost';
const API_LOOPBACK_HTTP_HOST = '127.0.0.1';
const FNV1A_32_OFFSET_BASIS = 0x811c9dc5;
const FNV1A_32_PRIME = 0x01000193;

function hashStringFNV1A(input: string): number {
	let hash = FNV1A_32_OFFSET_BASIS;
	for (let index = 0; index < input.length; index += 1) {
		hash ^= input.charCodeAt(index);
		hash = Math.imul(hash, FNV1A_32_PRIME);
	}
	return hash >>> 0;
}

function parsePlaywrightWebPort(rawPort: string): number {
	if (!/^\d+$/.test(rawPort)) {
		throw new Error(
			`${PLAYWRIGHT_WEB_PORT_ENV} must be an integer TCP port when set (received "${rawPort}")`
		);
	}
	const parsedPort = Number(rawPort);
	if (!Number.isInteger(parsedPort) || parsedPort < 1024 || parsedPort > 65535) {
		throw new Error(
			`${PLAYWRIGHT_WEB_PORT_ENV} must be between 1024 and 65535 when set (received "${rawPort}")`
		);
	}
	return parsedPort;
}

export function resolveDefaultPlaywrightWebPort(workspacePath: string = process.cwd()): number {
	const normalizedWorkspacePath = workspacePath.trim();
	if (normalizedWorkspacePath.length === 0) {
		return 5173;
	}
	const portOffset = hashStringFNV1A(normalizedWorkspacePath) % PLAYWRIGHT_DEFAULT_PORT_HASH_SPAN;
	return PLAYWRIGHT_DEFAULT_PORT_HASH_MIN + portOffset;
}

export function resolveDefaultPlaywrightApiPort(workspacePath: string = process.cwd()): number {
	const normalizedWorkspacePath = workspacePath.trim();
	if (normalizedWorkspacePath.length === 0) {
		return 3001;
	}
	const portOffset = hashStringFNV1A(normalizedWorkspacePath) % PLAYWRIGHT_DEFAULT_PORT_HASH_SPAN;
	return PLAYWRIGHT_DEFAULT_API_PORT_HASH_MIN + portOffset;
}

export function resolveDefaultPlaywrightFlapjackPort(
	workspacePath: string = process.cwd()
): number {
	const normalizedWorkspacePath = workspacePath.trim();
	if (normalizedWorkspacePath.length === 0) {
		// Mirror the web/API resolvers' empty-path fallback: a fixed default that
		// matches the legacy hardcoded DEFAULT_FLAPJACK_URL port (7700) so callers
		// with no workspace context keep the historical behavior.
		return 7700;
	}
	const portOffset = hashStringFNV1A(normalizedWorkspacePath) % PLAYWRIGHT_DEFAULT_PORT_HASH_SPAN;
	return PLAYWRIGHT_DEFAULT_FLAPJACK_PORT_HASH_MIN + portOffset;
}

function buildPlaywrightApiUrl(port: number): string {
	return `http://${API_LOOPBACK_HTTP_HOST}:${port}`;
}

function buildExplicitLoopbackWebServerCommand(baseURL: string): string {
	const parsedBaseUrl = new URL(baseURL);
	const port = parsedBaseUrl.port || (parsedBaseUrl.protocol === 'https:' ? '443' : '80');
	return `${PLAYWRIGHT_WEB_ONLY_SERVER_COMMAND} --host ${parsedBaseUrl.hostname} --port ${port} --strictPort`;
}

export const DEFAULT_API_URL = buildPlaywrightApiUrl(resolveDefaultPlaywrightApiPort());

function resolvePlaywrightWebPort(
	processEnv: Record<string, string | undefined>,
	workspacePath: string
): number {
	const configuredPort = processEnv[PLAYWRIGHT_WEB_PORT_ENV]?.trim();
	if (configuredPort && configuredPort.length > 0) {
		return parsePlaywrightWebPort(configuredPort);
	}
	return resolveDefaultPlaywrightWebPort(workspacePath);
}

function resolvePlaywrightApiPort(
	processEnv: Record<string, string | undefined>,
	workspacePath: string
): number {
	const configuredPort = processEnv[PLAYWRIGHT_API_PORT_ENV]?.trim();
	if (configuredPort && configuredPort.length > 0) {
		return parsePlaywrightWebPort(configuredPort);
	}
	return resolveDefaultPlaywrightApiPort(workspacePath);
}

function resolvePlaywrightFlapjackPort(
	processEnv: Record<string, string | undefined>,
	workspacePath: string
): number {
	const configuredPort = processEnv[PLAYWRIGHT_FLAPJACK_PORT_ENV]?.trim();
	if (configuredPort && configuredPort.length > 0) {
		// Reuse the web-port parser: same 1024–65535 integer contract.
		return parsePlaywrightWebPort(configuredPort);
	}
	return resolveDefaultPlaywrightFlapjackPort(workspacePath);
}

function buildPlaywrightLoopbackUrl(port: number): string {
	return `http://localhost:${port}`;
}

export const PLAYWRIGHT_PROJECT_CONTRACTS: PlaywrightProjectContract[] = [
	{
		name: 'setup:user',
		testMatch: /fixtures\/auth\.setup\.ts/
	},
	{
		name: 'setup:admin',
		testMatch: /fixtures\/admin\.auth\.setup\.ts/
	},
	{
		name: 'setup:onboarding',
		testMatch: /fixtures\/onboarding\.auth\.setup\.ts/
	},
	{
		name: 'setup:customer-journeys',
		testMatch: /fixtures\/customer-journeys\.auth\.setup\.ts/
	},
	{
		name: 'chromium:public',
		testMatch: /e2e-ui\/(smoke|full)\/public-.+\.spec\.ts/,
		use: { desktopBrowser: 'chromium' }
	},
	{
		name: 'chromium:signup',
		testMatch: /e2e-ui\/full\/signup_to_paid_invoice\.spec\.ts/,
		use: { desktopBrowser: 'chromium' }
	},
	{
		name: 'chromium:mocked',
		testMatch: /e2e-ui\/mocked\/.+\.spec\.ts/,
		dependencies: ['setup:user'],
		use: {
			desktopBrowser: 'chromium',
			storageState: PLAYWRIGHT_STORAGE_STATE.user
		}
	},
	{
		name: 'chromium',
		testMatch:
			/e2e-ui\/(smoke|full)\/(?!admin|public-|onboarding\.|customer-journeys\.|signup_to_paid_invoice\.).+\.spec\.ts/,
		dependencies: ['setup:user'],
		use: {
			desktopBrowser: 'chromium',
			storageState: PLAYWRIGHT_STORAGE_STATE.user
		}
	},
	{
		name: 'chromium:onboarding',
		testMatch: /e2e-ui\/full\/onboarding\.spec\.ts/,
		dependencies: ['setup:onboarding'],
		use: {
			desktopBrowser: 'chromium',
			storageState: PLAYWRIGHT_STORAGE_STATE.onboarding,
			trace: 'off',
			screenshot: 'off'
		}
	},
	{
		name: 'chromium:customer-journeys',
		testMatch: /e2e-ui\/full\/customer-journeys\.spec\.ts/,
		dependencies: ['setup:customer-journeys'],
		use: {
			desktopBrowser: 'chromium',
			storageState: PLAYWRIGHT_STORAGE_STATE.customerJourneys,
			trace: 'off',
			screenshot: 'off'
		}
	},
	{
		name: 'chromium:admin',
		testMatch: /e2e-ui\/full\/admin\/.+\.spec\.ts/,
		dependencies: ['setup:admin'],
		use: {
			desktopBrowser: 'chromium',
			storageState: PLAYWRIGHT_STORAGE_STATE.admin
		}
	}
];

/** Parse KEY=value pairs from a dotenv file into a string record, skipping blanks, comments, and invalid lines. */
export function parseDotenvFile(filePath: string): Record<string, string> {
	if (!existsSync(filePath)) {
		return {};
	}

	const env: Record<string, string> = {};
	for (const rawLine of readFileSync(filePath, 'utf8').split(/\r?\n/)) {
		const line = rawLine.trim();
		if (line.length === 0 || line.startsWith('#')) {
			continue;
		}

		const normalizedLine = line.startsWith('export ') ? line.slice('export '.length).trim() : line;
		const separatorIndex = normalizedLine.indexOf('=');
		if (separatorIndex <= 0) {
			continue;
		}

		const key = normalizedLine.slice(0, separatorIndex).trim();
		if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
			continue;
		}

		const rawValue = normalizedLine.slice(separatorIndex + 1).trim();
		env[key] = parseDotenvValue(rawValue);
	}

	return env;
}

/** Strip matching outer quotes and unescape double-quoted sequences; strip inline comments from unquoted values. */
export function parseDotenvValue(rawValue: string): string {
	if (
		rawValue.length >= 2 &&
		((rawValue.startsWith('"') && rawValue.endsWith('"')) ||
			(rawValue.startsWith("'") && rawValue.endsWith("'")))
	) {
		const inner = rawValue.slice(1, -1);
		return rawValue.startsWith('"')
			? inner.replace(/\\\\/g, '\\').replace(/\\n/g, '\n').replace(/\\"/g, '"')
			: inner;
	}

	return rawValue.replace(/\s+#.*$/, '').trim();
}

export function sanitizeWebServerEnv(
	env: Record<string, string | undefined>
): Record<string, string> {
	// Filter out undefined values so the result is a clean Record<string, string>
	const entries = Object.entries(env).filter(
		(entry): entry is [string, string] => typeof entry[1] === 'string'
	);
	return Object.fromEntries(entries);
}

const PLAYWRIGHT_SECRET_ENV_KEYS = [
	'STRIPE_SECRET_KEY',
	'STRIPE_TEST_SECRET_KEY',
	'STRIPE_WEBHOOK_SECRET'
] as const;

export function selectPlaywrightSecretEnv(
	env: Record<string, string | undefined>
): Record<string, string> {
	const selected: Record<string, string> = {};
	for (const key of PLAYWRIGHT_SECRET_ENV_KEYS) {
		const value = env[key];
		if (typeof value === 'string' && value.length > 0) {
			selected[key] = value;
		}
	}
	return selected;
}

function firstDefinedEnvValue(...values: Array<string | undefined>): string | undefined {
	return values.find((value) => value !== undefined && value !== '');
}

function isNoDepsPlaywrightSelection(argv: string[]): boolean {
	return argv.includes('--no-deps');
}

function isRemoteTargetOptInActive(processEnv: Record<string, string | undefined>): boolean {
	return processEnv[REMOTE_TARGET_OPT_IN_ENV] === '1';
}

function assignFirstDefinedEnvValue(
	processEnv: Record<string, string | undefined>,
	key: string,
	...values: Array<string | undefined>
): void {
	const resolvedValue = firstDefinedEnvValue(...values);
	if (resolvedValue !== undefined) {
		processEnv[key] = resolvedValue;
	}
}

/**
 * TODO: Document applyPlaywrightProcessEnvDefaults.
 */
export function applyPlaywrightProcessEnvDefaults({
	processEnv,
	repoEnv,
	webEnv
}: ApplyPlaywrightProcessEnvDefaultsParams): void {
	const allowLocalCredentialFallbacks = !isRemoteTargetOptInActive(processEnv);
	// Terminal fallback to DEFAULT_PLAYWRIGHT_ADMIN_KEY ensures workers see the
	// same key that resolvePlaywrightRuntime passes to the web server when no
	// .env.local or explicit ADMIN_KEY is available. Remote-target mode must
	// fail closed instead of sending local-dev fallbacks to an allowlisted
	// non-loopback host.
	assignFirstDefinedEnvValue(
		processEnv,
		'E2E_ADMIN_KEY',
		processEnv.E2E_ADMIN_KEY,
		allowLocalCredentialFallbacks ? webEnv.E2E_ADMIN_KEY : undefined,
		allowLocalCredentialFallbacks ? repoEnv.E2E_ADMIN_KEY : undefined,
		allowLocalCredentialFallbacks ? webEnv.ADMIN_KEY : undefined,
		allowLocalCredentialFallbacks ? repoEnv.ADMIN_KEY : undefined,
		allowLocalCredentialFallbacks ? processEnv.ADMIN_KEY : undefined,
		allowLocalCredentialFallbacks ? DEFAULT_PLAYWRIGHT_ADMIN_KEY : undefined
	);
	assignFirstDefinedEnvValue(
		processEnv,
		'E2E_USER_EMAIL',
		processEnv.E2E_USER_EMAIL,
		webEnv.E2E_USER_EMAIL,
		repoEnv.E2E_USER_EMAIL,
		processEnv.SEED_USER_EMAIL,
		repoEnv.SEED_USER_EMAIL,
		webEnv.SEED_USER_EMAIL,
		allowLocalCredentialFallbacks ? DEFAULT_E2E_USER_EMAIL : undefined
	);
	assignFirstDefinedEnvValue(
		processEnv,
		'E2E_USER_PASSWORD',
		processEnv.E2E_USER_PASSWORD,
		webEnv.E2E_USER_PASSWORD,
		repoEnv.E2E_USER_PASSWORD,
		processEnv.SEED_USER_PASSWORD,
		repoEnv.SEED_USER_PASSWORD,
		webEnv.SEED_USER_PASSWORD,
		allowLocalCredentialFallbacks ? DEFAULT_E2E_USER_PASSWORD : undefined
	);
	assignFirstDefinedEnvValue(
		processEnv,
		'DATABASE_URL',
		processEnv.DATABASE_URL,
		repoEnv.DATABASE_URL,
		webEnv.DATABASE_URL
	);
	assignFirstDefinedEnvValue(
		processEnv,
		'MAILPIT_API_URL',
		processEnv.MAILPIT_API_URL,
		webEnv.MAILPIT_API_URL,
		repoEnv.MAILPIT_API_URL
	);
	assignFirstDefinedEnvValue(
		processEnv,
		'STRIPE_WEBHOOK_SECRET',
		processEnv.STRIPE_WEBHOOK_SECRET,
		webEnv.STRIPE_WEBHOOK_SECRET,
		repoEnv.STRIPE_WEBHOOK_SECRET
	);
	assignFirstDefinedEnvValue(
		processEnv,
		'STRIPE_SECRET_KEY',
		processEnv.STRIPE_SECRET_KEY,
		processEnv.STRIPE_TEST_SECRET_KEY,
		webEnv.STRIPE_SECRET_KEY,
		webEnv.STRIPE_TEST_SECRET_KEY,
		repoEnv.STRIPE_SECRET_KEY,
		repoEnv.STRIPE_TEST_SECRET_KEY
	);
}

/**
 * Resolve Playwright runtime configuration from process/repo/web env sources with
 * loopback-only URL guardrails. BASE_URL stays process-owned for local reruns,
 * API_BASE_URL follows explicit process overrides before file-backed defaults, and
 * the spawned web server keeps its existing JWT/admin-key fallback behavior.
 */
export function resolvePlaywrightRuntime({
	processEnv,
	repoEnv,
	webEnv,
	fallbackJwtSecret,
	argv = [],
	workspacePath = process.cwd()
}: ResolvePlaywrightRuntimeParams): PlaywrightRuntimeContract {
	const webPort = resolvePlaywrightWebPort(processEnv, workspacePath);
	const apiPort = resolvePlaywrightApiPort(processEnv, workspacePath);
	const flapjackPort = resolvePlaywrightFlapjackPort(processEnv, workspacePath);
	const defaultBaseUrl = buildPlaywrightLoopbackUrl(webPort);
	const defaultApiBaseUrl = buildPlaywrightApiUrl(apiPort);
	// Per-workspace flapjack URL — replaces the legacy hardcoded DEFAULT_FLAPJACK_URL.
	// Threaded into BOTH the spawned stack (webServerEnv → playwright_local_stack.sh
	// starts + targets flapjack here, the API inherits it) AND the fixture process
	// (processEnv.FLAPJACK_URL → resolveFixtureEnv → seedIndex's create body
	// `flapjack_url`), so the provisioned node and the proxy agree on one isolated
	// flapjack. Without this thread, seedIndex would point nodes at :7700 (a foreign
	// worktree's flapjack) while the stack ran its own — the 403 auth-mismatch source.
	const defaultFlapjackUrl = buildPlaywrightLoopbackUrl(flapjackPort);
	const hasExplicitBaseUrl = Boolean(processEnv.BASE_URL && processEnv.BASE_URL.trim().length > 0);
	// Thread processEnv through so the LB-2/LB-3 remote-target opt-in
	// (PLAYWRIGHT_TARGET_REMOTE=1) is observed deterministically by the
	// loopback guard during runtime resolution.
	const baseURL = requireLoopbackHttpUrl(
		'BASE_URL',
		processEnv.BASE_URL ?? defaultBaseUrl,
		processEnv
	);
	const shouldStartExplicitNoDepsWebServer =
		hasExplicitBaseUrl &&
		isNoDepsPlaywrightSelection(argv) &&
		!isRemoteTargetOptInActive(processEnv);
	if (!hasExplicitBaseUrl) {
		processEnv.BASE_URL = baseURL;
		// Local spawned-stack runs must ignore static API_BASE_URL/API_URL values
		// from shared .env.local to prevent cross-worktree port contention.
		if (!processEnv.API_BASE_URL || processEnv.API_BASE_URL.trim().length === 0) {
			processEnv.API_BASE_URL = defaultApiBaseUrl;
		}
		if (!processEnv.API_URL || processEnv.API_URL.trim().length === 0) {
			processEnv.API_URL = defaultApiBaseUrl;
		}
		if (
			!processEnv[PLAYWRIGHT_API_PORT_ENV] ||
			processEnv[PLAYWRIGHT_API_PORT_ENV]?.trim().length === 0
		) {
			processEnv[PLAYWRIGHT_API_PORT_ENV] = String(apiPort);
		}
		// Pin the fixture process to the workspace flapjack port so seedIndex /
		// resolveFixtureEnv provision nodes against the same instance the stack runs.
		// Respect an explicit FLAPJACK_URL (e.g. a deliberate override) when present.
		if (!processEnv.FLAPJACK_URL || processEnv.FLAPJACK_URL.trim().length === 0) {
			processEnv.FLAPJACK_URL = defaultFlapjackUrl;
		}
		if (
			!processEnv.LOCAL_DEV_FLAPJACK_URL ||
			processEnv.LOCAL_DEV_FLAPJACK_URL.trim().length === 0
		) {
			processEnv.LOCAL_DEV_FLAPJACK_URL = defaultFlapjackUrl;
		}
		if (
			!processEnv[PLAYWRIGHT_FLAPJACK_PORT_ENV] ||
			processEnv[PLAYWRIGHT_FLAPJACK_PORT_ENV]?.trim().length === 0
		) {
			processEnv[PLAYWRIGHT_FLAPJACK_PORT_ENV] = String(flapjackPort);
		}
	}
	const apiBaseUrl = requireLoopbackHttpUrl(
		'API_BASE_URL',
		processEnv.API_BASE_URL ?? repoEnv.API_BASE_URL ?? webEnv.API_BASE_URL ?? defaultApiBaseUrl,
		processEnv
	);
	const apiUrl = requireLoopbackHttpUrl(
		'API_URL',
		processEnv.API_URL ?? repoEnv.API_URL ?? webEnv.API_URL ?? defaultApiBaseUrl,
		processEnv
	);
	processEnv.API_BASE_URL = apiBaseUrl;
	processEnv.API_URL = apiUrl;
	const webServerEnv = sanitizeWebServerEnv({
		...processEnv,
		...repoEnv,
		...webEnv,
		API_BASE_URL: apiBaseUrl,
		API_URL: apiUrl,
		[PLAYWRIGHT_API_PORT_ENV]: String(apiPort),
		[PLAYWRIGHT_FLAPJACK_PORT_ENV]: String(flapjackPort),
		// Workspace-isolated flapjack URL (see defaultFlapjackUrl above). Prefer an
		// explicit FLAPJACK_URL the !hasExplicitBaseUrl block already pinned, falling
		// back to the derived per-workspace URL for the remote-target path.
		FLAPJACK_URL: processEnv.FLAPJACK_URL ?? defaultFlapjackUrl,
		LOCAL_DEV_FLAPJACK_URL: processEnv.LOCAL_DEV_FLAPJACK_URL ?? defaultFlapjackUrl,
		// Keep spawned API listen addresses pinned to the computed Playwright
		// API port so stale repo env LISTEN_ADDR values (for example 3001) cannot
		// drift away from the health-check target and stall webServer startup.
		LISTEN_ADDR: `${API_LOOPBACK_HTTP_HOST}:${apiPort}`,
		S3_LISTEN_ADDR: `${API_LOOPBACK_HTTP_HOST}:${apiPort + 1}`,
		JWT_SECRET:
			processEnv.JWT_SECRET ?? webEnv.JWT_SECRET ?? repoEnv.JWT_SECRET ?? fallbackJwtSecret,
		ADMIN_KEY:
			processEnv.E2E_ADMIN_KEY ??
			webEnv.ADMIN_KEY ??
			repoEnv.ADMIN_KEY ??
			processEnv.ADMIN_KEY ??
			DEFAULT_PLAYWRIGHT_ADMIN_KEY,
		// The Apr27 hardening (commit d4dde081 "Harden signup verification
		// bypass") gated SKIP_EMAIL_VERIFICATION on ENVIRONMENT ∈
		// {local,dev,development}. Both must be set together for the spawned
		// API server to auto-verify signups, otherwise /signup → /console
		// redirects back to /login because verification is required, breaking
		// every fixture in tests/fixtures/onboarding-auth-shared.ts and
		// auth.setup.ts. These ONLY apply to the locally-spawned webServer
		// (this whole block is skipped when processEnv.BASE_URL is set, e.g.
		// running playwright against a real remote deploy).
		ENVIRONMENT: 'local',
		SKIP_EMAIL_VERIFICATION: '1',
		API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION: '1'
	});

	return {
		baseURL,
		webServerEnv,
		webServer: shouldStartExplicitNoDepsWebServer
			? {
					command: buildExplicitLoopbackWebServerCommand(baseURL),
					env: webServerEnv,
					url: baseURL,
					reuseExistingServer: false,
					timeout: PLAYWRIGHT_WEB_SERVER_TIMEOUT_MS
				}
			: hasExplicitBaseUrl
				? undefined
				: {
						command: `${
							isPublicOnlyPlaywrightSelection(argv)
								? PLAYWRIGHT_WEB_ONLY_SERVER_COMMAND
								: PLAYWRIGHT_WEB_SERVER_COMMAND
						} --host ${LOOPBACK_HTTP_HOST} --port ${webPort} --strictPort`,
						env: webServerEnv,
						url: baseURL,
						reuseExistingServer: false,
						timeout: PLAYWRIGHT_WEB_SERVER_TIMEOUT_MS
					}
	};
}

// ---------------------------------------------------------------------------
// Fixture-side env resolution — single owner for env name strings and defaults
// that were previously duplicated across fixtures.ts, searchable-index.ts,
// auth.setup.ts, and admin.auth.setup.ts.
// ---------------------------------------------------------------------------

export type FixtureEnv = {
	apiUrl: string;
	adminKey: string | undefined;
	userEmail: string | undefined;
	userPassword: string | undefined;
	testRegion: string;
	flapjackUrl: string;
};

const LOOPBACK_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]']);

// LB-2/LB-3 — opt-in remote-target mode for running browser specs against
// deployed staging. Both conditions must be satisfied to bypass the loopback
// check: (1) processEnv[REMOTE_TARGET_OPT_IN_ENV] === '1' (literal "1" only,
// not generic truthy values, to keep the carve-out unambiguous and grep-able);
// (2) URL host ends with one of REMOTE_TARGET_HOST_SUFFIX_ALLOWLIST. The
// suffix match is anchored on a literal "." prefix to prevent
// flapjack.foo.evil.com style bypass. Remote-target mode also requires https
// because the credentialed flow exports ADMIN_KEY/JWT to the wire.
//
// SSoT: this is the ONLY place the carve-out is implemented. All non-local
// fixtures call requireLoopbackHttpUrl() and inherit this behavior.
export const REMOTE_TARGET_OPT_IN_ENV = 'PLAYWRIGHT_TARGET_REMOTE';
export const REMOTE_TARGET_HOST_SUFFIX_ALLOWLIST: readonly string[] = [
	// Canonical staging+prod root for fjcloud (api.flapjack.foo,
	// cloud.flapjack.foo, flapjack.flapjack.foo). Adding more entries here
	// MUST be paired with an explicit security review — every entry widens
	// where credentialed Playwright runs may direct traffic.
	'.flapjack.foo'
];

function isAllowlistedRemoteTargetHost(hostname: string): boolean {
	// Anchored suffix match — only allow when hostname ENDS with an
	// allowlisted suffix. The leading "." in each allowlist entry prevents
	// substring-style bypass like "flapjack.foo.evil.com".
	for (const suffix of REMOTE_TARGET_HOST_SUFFIX_ALLOWLIST) {
		if (hostname.endsWith(suffix)) {
			return true;
		}
	}
	return false;
}

/**
 * TODO: Document assertSafeRemoteTargetUrl.
 */
function assertSafeRemoteTargetUrl(varName: string, parsed: URL): void {
	if (parsed.username || parsed.password) {
		throw new Error(
			`${varName} must not embed URL credentials when ${REMOTE_TARGET_OPT_IN_ENV}=1`
		);
	}
	if (parsed.port && parsed.port !== '443') {
		throw new Error(
			`${varName} must use the default https port when ${REMOTE_TARGET_OPT_IN_ENV}=1`
		);
	}
	if (parsed.pathname !== '/' || parsed.search || parsed.hash) {
		throw new Error(
			`${varName} must be a bare https origin without path, query, or fragment when ${REMOTE_TARGET_OPT_IN_ENV}=1`
		);
	}
}

/**
 * Reject any URL that is not http/https on a loopback host to prevent
 * credentialed requests leaking to non-local endpoints.
 *
 * processEnv defaults to process.env so existing callers need no change. When
 * processEnv[REMOTE_TARGET_OPT_IN_ENV] === '1' AND the URL host matches the
 * staging-only allowlist AND the protocol is https, the loopback check is
 * waived. See REMOTE_TARGET_HOST_SUFFIX_ALLOWLIST and LB-2/LB-3 in
 * LAUNCH.md for context.
 */
export function requireLoopbackHttpUrl(
	varName: string,
	rawUrl: string,
	processEnv: Record<string, string | undefined> = process.env
): string {
	let parsed: URL;
	try {
		parsed = new URL(rawUrl);
	} catch {
		throw new Error(
			`${varName} must be a valid http:// or https:// loopback URL for credentialed local browser runs`
		);
	}

	if (!['http:', 'https:'].includes(parsed.protocol) || !LOOPBACK_HOSTS.has(parsed.hostname)) {
		// Default-deny: only the explicit "1" opt-in flag + allowlisted https
		// host can lift the loopback gate. Any other combination remains
		// rejected to preserve the original safety posture.
		const optInActive = processEnv[REMOTE_TARGET_OPT_IN_ENV] === '1';
		if (
			optInActive &&
			parsed.protocol === 'https:' &&
			isAllowlistedRemoteTargetHost(parsed.hostname)
		) {
			assertSafeRemoteTargetUrl(varName, parsed);
			return rawUrl;
		}

		// When opt-in is set but host is not on allowlist (or http instead
		// of https), surface a more specific error so the operator knows
		// remote-target mode IS active but their URL was rejected by the
		// allowlist/protocol rule rather than the original loopback rule.
		if (optInActive && parsed.protocol !== 'https:') {
			throw new Error(
				`${varName} must use https when ${REMOTE_TARGET_OPT_IN_ENV}=1 (refusing to send credentialed requests over an unencrypted channel to a non-loopback host)`
			);
		}

		throw new Error(
			`${varName} must use a local loopback host (localhost, 127.0.0.1, or [::1]) for credentialed local browser runs`
		);
	}

	return rawUrl;
}

/**
 * TODO: Document resolveFixtureEnv.
 */
export function resolveFixtureEnv(processEnv: Record<string, string | undefined>): FixtureEnv {
	// Thread processEnv into the loopback guard so the LB-2/LB-3
	// remote-target opt-in (PLAYWRIGHT_TARGET_REMOTE=1) is observed
	// deterministically during fixture-env resolution rather than racing
	// against process.env at module load time.
	return {
		apiUrl: requireLoopbackHttpUrl('API_URL', processEnv.API_URL ?? DEFAULT_API_URL, processEnv),
		adminKey: processEnv.E2E_ADMIN_KEY ?? processEnv.ADMIN_KEY,
		userEmail: processEnv.E2E_USER_EMAIL,
		userPassword: processEnv.E2E_USER_PASSWORD,
		testRegion: processEnv.E2E_TEST_REGION ?? DEFAULT_TEST_REGION,
		flapjackUrl: requireLoopbackHttpUrl(
			'FLAPJACK_URL',
			processEnv.FLAPJACK_URL ?? DEFAULT_FLAPJACK_URL,
			processEnv
		)
	};
}

export function resolveRequiredFixtureUserCredentials(
	processEnv: Record<string, string | undefined>
): { email: string; password: string } {
	const credentialError =
		'E2E_USER_EMAIL and E2E_USER_PASSWORD must be set to run browser-unmocked tests';
	const email = requireNonEmptyString(processEnv.E2E_USER_EMAIL ?? '', credentialError);
	const password = requireNonBlankString(processEnv.E2E_USER_PASSWORD ?? '', credentialError);
	return { email, password };
}

export function resolveRequiredFixtureAdminKey(
	processEnv: Record<string, string | undefined>
): string {
	return requireNonBlankString(
		processEnv.E2E_ADMIN_KEY ?? processEnv.ADMIN_KEY ?? '',
		'E2E_ADMIN_KEY must be set to run admin browser-unmocked tests'
	);
}
/**
 * @module Stub summary for web/tests/fixtures/fixtures.ts.
 */
/**
 * Shared Playwright test fixtures.
 *
 * Spec files import { test, expect } from this module instead of directly
 * from @playwright/test.  Custom fixtures handle data seeding and automatic
 * cleanup so spec files never need to call request.* themselves.
 *
 * API calls here are ARRANGE-phase shortcuts, explicitly allowed by
 * BROWSER_TESTING_STANDARDS_2.md.  They must never appear in *.spec.ts files.
 */

import { test as base, expect, type Page } from '@playwright/test';
import { existsSync, readFileSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { createSeedSearchableIndexFactory, type SeedSearchableIndexFn } from './searchable-index';
import { buildTenantScopedIndexUid } from '../../src/lib/flapjack-index';
import {
	findCustomerStatusViaStagingSsm,
	findPaidInvoiceEvidenceViaStagingSsm,
	findVerificationTokenViaStagingSsm,
	type StagingCustomerStatusEvidence,
	type StagingPaidInvoiceEvidence
} from './staging_db_lookup';
import { readStripeDefaultPaymentMethod } from './staging_stripe_lookup';
import {
	DEFAULT_API_URL,
	REMOTE_TARGET_OPT_IN_ENV,
	parseDotenvFile,
	requireLoopbackHttpUrl,
	resolveFixtureEnv,
	resolveRequiredFixtureUserCredentials
} from '../../playwright.config.contract';
import { AUTH_COOKIE } from '../../src/lib/server/auth-session-contracts';
import { requireAdminApiKey, requireNonEmptyString } from './contract-guards';
import {
	attemptRemoteSignupFallback,
	isRemoteTargetMode,
	setAuthCookieForToken
} from './fresh_signup_remote_bootstrap';
import type {
	ApiKeyListItem,
	DebugEvent,
	EstimatedBillResponse,
	Rule,
	RuleSearchResponse,
	Synonym,
	SynonymSearchResponse
} from '../../src/lib/api/types';
import type { AdminRateCard } from '../../src/lib/admin-client';
import {
	pricingContractSnapshotFromAdminRateCard,
	type MarketingPricingContractSnapshot
} from '../../src/lib/pricing';
import { quoteSqlLiteral, runSqlWithPsqlFallback } from './postgres_psql_helper';
import { formatFixtureSetupFailure, redactSensitiveDiagnostics } from './setup_failure_message';
export { formatFixtureSetupFailure } from './setup_failure_message';

// ---------------------------------------------------------------------------
// Internal HTTP helpers — never imported by spec files
// ---------------------------------------------------------------------------

type ResolvedFixtureEnv = ReturnType<typeof resolveFixtureEnv>;

function currentFixtureEnv(): ResolvedFixtureEnv {
	return resolveFixtureEnv(process.env);
}

function fixtureEnvForFailureDiagnostics(): { apiUrl: string; adminKey: string | undefined } {
	try {
		const resolved = currentFixtureEnv();
		return {
			apiUrl: resolved.apiUrl,
			adminKey: resolved.adminKey
		};
	} catch {
		return {
			apiUrl: process.env.API_URL?.trim() || process.env.API_BASE_URL?.trim() || DEFAULT_API_URL,
			adminKey: process.env.E2E_ADMIN_KEY ?? process.env.ADMIN_KEY
		};
	}
}

/**
 * TODO: Document verifyTrackedCustomerEmailForRemote.
 */
async function verifyTrackedCustomerEmailForRemote(email: string): Promise<void> {
	if (!isRemoteTargetMode()) {
		return;
	}

	const verificationToken = await findVerificationTokenViaStagingSsm(email);
	for (let attempt = 0; attempt < TRANSIENT_API_MAX_RETRIES; attempt += 1) {
		const response = await callJsonApi(
			fetch,
			fixtureEnv.apiUrl,
			'POST',
			'/auth/verify-email',
			{},
			{ token: verificationToken }
		);
		if (response.ok) {
			return;
		}
		if (response.status === 429) {
			await sleep(getRetryDelayMs(attempt, response.headers.get('retry-after')));
			continue;
		}
		const requestId =
			response.headers.get('x-request-id') ?? response.headers.get('x-amzn-requestid') ?? '';
		throw new Error(
			`arrangeTrackedCustomerSession email verification failed: status=${response.status}${
				requestId ? ` request_id=${requestId}` : ''
			}`
		);
	}
	throw new Error(
		'arrangeTrackedCustomerSession email verification failed: exhausted retries after 429 rate limiting'
	);
}

// Resolve fixture env lazily so unit tests can import this module without
// immediately enforcing loopback constraints on the ambient shell env.
const fixtureEnv = {
	get apiUrl() {
		return currentFixtureEnv().apiUrl;
	},
	get adminKey() {
		return currentFixtureEnv().adminKey;
	},
	get userEmail() {
		return currentFixtureEnv().userEmail;
	},
	get userPassword() {
		return currentFixtureEnv().userPassword;
	},
	get testRegion() {
		return currentFixtureEnv().testRegion;
	},
	get flapjackUrl() {
		return currentFixtureEnv().flapjackUrl;
	}
} as ResolvedFixtureEnv;

let _token: string | null = null;
let _customerId: string | null = null;
let _staleFixtureIndexesCleaned = false;
let _staleFixtureIndexesCleanupCooldownUntil = 0;
type CleanupStaleFixtureIndexesOnceOptions = {
	force?: boolean;
	apiCall?: FixtureApiCall;
	now?: () => number;
	sleep?: (ms: number) => Promise<void>;
};
type FixtureApiCall = (
	method: string,
	path: string,
	body?: unknown,
	tokenOverride?: string
) => Promise<Response>;
type EnsureLocalSharedVmInventoryForRegionDeps = {
	env?: Record<string, string | undefined>;
	flapjackUrl?: string;
	databaseUrl?: string | null;
	runSql?: (databaseUrl: string, sql: string, context: string) => unknown;
};
type StaleFixtureIndexCleanupState = {
	cleaned: boolean;
	cooldownUntil: number;
};
type RunTrackedIndexCleanupDeps = {
	apiCall?: FixtureApiCall;
};
type RunTrackedCustomerCleanupDeps = {
	deleteTrackedCustomerForCleanup?: (customerId: string) => Promise<void>;
};
type AdminDeploymentFixture = {
	id: string;
	region: string;
	status: string;
};

function resolveFixtureContractPath(relativePath: string): string {
	const contractPath = [
		path.resolve(process.cwd(), relativePath),
		path.resolve(process.cwd(), '..', relativePath)
	].find((candidate) => existsSync(candidate));
	if (!contractPath) {
		throw new Error(`${relativePath} not found from fixture cwd`);
	}
	return contractPath;
}

function readShellStringAssignment(contractPath: string, variableName: string): string {
	const contractSource = readFileSync(contractPath, 'utf8');
	const assignmentMatch = contractSource.match(new RegExp(`^${variableName}=(['"])(.*?)\\1$`, 'm'));
	if (!assignmentMatch) {
		throw new Error(`${contractPath} missing ${variableName}`);
	}
	return assignmentMatch[2];
}

function readShellArrayAssignment(contractPath: string, variableName: string): readonly string[] {
	const contractSource = readFileSync(contractPath, 'utf8');
	const arrayMatch = contractSource.match(new RegExp(`${variableName}=\\(([\\s\\S]*?)\\)`, 'm'));
	if (!arrayMatch) {
		throw new Error(`${contractPath} missing ${variableName}`);
	}

	const values = [...arrayMatch[1].matchAll(/"([^"]+)"/g)].map((match) => match[1]);
	if (values.length === 0) {
		throw new Error(`${contractPath} has no ${variableName} values`);
	}
	return values;
}

const LOCAL_SEED_CONTRACT_PATH = resolveFixtureContractPath('scripts/lib/local_seed_contract.sh');
const STALE_FIXTURE_CONTRACT_PATH = resolveFixtureContractPath(
	'scripts/lib/stale_fixture_contract.sh'
);
const LOCAL_VM_CAPACITY_JSON = readShellStringAssignment(
	LOCAL_SEED_CONTRACT_PATH,
	'LOCAL_SEED_VM_CAPACITY_JSON'
);
const LOCAL_VM_CURRENT_LOAD_JSON = readShellStringAssignment(
	LOCAL_SEED_CONTRACT_PATH,
	'LOCAL_SEED_VM_CURRENT_LOAD_JSON'
);

/**
 * TODO: Document fixtureLocalDatabaseUrl.
 */
function fixtureLocalDatabaseUrl(): string | null {
	const directDatabaseUrl = process.env.DATABASE_URL?.trim();
	if (directDatabaseUrl) {
		return directDatabaseUrl;
	}

	const dotenvCandidates = [
		path.resolve(process.cwd(), '.env.local'),
		path.resolve(process.cwd(), '..', '.env.local')
	];
	for (const dotenvPath of dotenvCandidates) {
		const databaseUrl = parseDotenvFile(dotenvPath).DATABASE_URL?.trim();
		if (databaseUrl) {
			return databaseUrl;
		}
	}

	return null;
}

function requireFixtureDatabaseUrl(context: string): string {
	const databaseUrl = fixtureLocalDatabaseUrl();
	if (!databaseUrl) {
		throw new Error(`${context} requires DATABASE_URL or web/.env.local DATABASE_URL`);
	}
	return databaseUrl;
}

function runFixtureSql(sql: string, context: string): string {
	return runSqlWithPsqlFallback(requireFixtureDatabaseUrl(context), sql, context).trim();
}

function assertSingleSqlUpdatedRow(output: string, context: string): void {
	const lines = output
		.split('\n')
		.map((line) => line.trim())
		.filter(Boolean);
	if (lines[lines.length - 1] === '1') {
		return;
	}
	throw new Error(`${context} did not update exactly one row. Output: ${output}`);
}

/** Reset a locally seeded tracked customer to the unverified-email state. */
async function forceTrackedCustomerEmailUnverifiedForLocal(email: string): Promise<void> {
	if (isRemoteTargetMode()) {
		return;
	}

	const quotedEmail = quoteSqlLiteral(email);
	const output = runFixtureSql(
		[
			'WITH updated AS (',
			'  UPDATE customers',
			'  SET email_verified_at = NULL,',
			"      email_verify_token = COALESCE(email_verify_token, 'e2e-unverified-' || replace(id::text, '-', '')),",
			"      email_verify_expires_at = COALESCE(email_verify_expires_at, NOW() + INTERVAL '24 hours'),",
			'      resend_verification_sent_at = NULL,',
			'      updated_at = NOW()',
			`  WHERE email = ${quotedEmail}`,
			"    AND status != 'deleted'",
			'  RETURNING 1',
			')',
			'SELECT COUNT(*) FROM updated;'
		].join('\n'),
		'arrangeTrackedCustomerSession local unverified setup'
	);
	assertSingleSqlUpdatedRow(output, 'arrangeTrackedCustomerSession local unverified setup');
}

/**
 * TODO: Document ensureLocalSharedVmInventoryForRegion.
 */
async function ensureLocalSharedVmInventoryForRegion(
	region: string,
	deps?: EnsureLocalSharedVmInventoryForRegionDeps
): Promise<void> {
	const env = deps?.env ?? process.env;
	if (env[REMOTE_TARGET_OPT_IN_ENV] === '1') {
		return;
	}

	const safeRegion = requireNonEmptyString(region, 'ensureLocalSharedVmInventory requires region');
	const safeFlapjackUrl = requireLoopbackHttpUrl(
		'FLAPJACK_URL',
		deps?.flapjackUrl ?? fixtureEnv.flapjackUrl
	);
	const databaseUrl = deps && 'databaseUrl' in deps ? deps.databaseUrl : fixtureLocalDatabaseUrl();
	if (!databaseUrl) {
		throw new Error(
			'DATABASE_URL must be set for local first-five-minutes UI create-index proof so vm_inventory can target the current Flapjack process.'
		);
	}

	const quotedRegion = quoteSqlLiteral(safeRegion);
	const quotedHostname = quoteSqlLiteral(`local-dev-${safeRegion}`);
	const quotedFlapjackUrl = quoteSqlLiteral(safeFlapjackUrl);
	const quotedCapacity = quoteSqlLiteral(LOCAL_VM_CAPACITY_JSON);
	const quotedCurrentLoad = quoteSqlLiteral(LOCAL_VM_CURRENT_LOAD_JSON);

	// The Playwright local stack moves Flapjack ports by workspace. Keep the
	// chosen browser region pointed at this session's Flapjack and drain stale
	// synthetic VMs left by earlier admin-seeded runs for the same local region.
	const runSql = deps?.runSql ?? runSqlWithPsqlFallback;
	runSql(
		databaseUrl,
		`
INSERT INTO vm_inventory (
    provider,
    hostname,
    flapjack_url,
    region,
    capacity,
    current_load,
    load_scraped_at,
    created_at,
    updated_at
)
VALUES (
    'local',
    ${quotedHostname},
    ${quotedFlapjackUrl},
    ${quotedRegion},
    ${quotedCapacity}::jsonb,
    ${quotedCurrentLoad}::jsonb,
    NOW(),
    NOW(),
    NOW()
)
ON CONFLICT (hostname) DO UPDATE
SET provider = EXCLUDED.provider,
    region = EXCLUDED.region,
    flapjack_url = EXCLUDED.flapjack_url,
    capacity = EXCLUDED.capacity,
    current_load = EXCLUDED.current_load,
    status = 'active',
    load_scraped_at = NOW(),
    updated_at = NOW();

UPDATE vm_inventory
SET status = 'decommissioned',
    updated_at = NOW()
WHERE provider = 'local'
  AND region = ${quotedRegion}
  AND status = 'active'
  AND hostname LIKE 'e2e-seed-%';
`,
		`local vm_inventory refresh for ${safeRegion}`
	);
}

const STALE_FIXTURE_INDEX_PREFIXES = readStaleFixtureIndexPrefixes();
const PASSIVE_STALE_INDEX_CLEANUP_DEADLINE_MS = 8_000;
const FORCE_STALE_INDEX_CLEANUP_DEADLINE_MS = 300_000;
const STAGE5_SYNONYMS_PROOF_MANIFEST_PATH = 'test-results/stage5-synonyms-proof.json';

function readStaleFixtureIndexPrefixes(): readonly string[] {
	return readShellArrayAssignment(STALE_FIXTURE_CONTRACT_PATH, 'STALE_FIXTURE_INDEX_PREFIXES');
}

export class FixtureAuthTokenInvalidError extends Error {
	status: number;

	constructor(status: number, details: string) {
		super(details);
		this.status = status;
		this.name = 'FixtureAuthTokenInvalidError';
	}
}

type BearerTokenRefreshDeps<T> = {
	getToken: () => Promise<string>;
	invalidateToken: () => void;
	invoke: (token: string) => Promise<T>;
};

// Shared bearer-token refresh seam: every authenticated fixture call routes
// through one of these helpers so a stale cached token (e.g. left behind by a
// local API restart) is invalidated and recovered the same way regardless of
// caller. Pure and DI-driven so tests can exercise the refresh logic without
// touching module-level state. Used by apiCall and getCustomerId.

/**
 * Run a bearer-authenticated operation that returns a Response, retrying once
 * with a refreshed token when the first response is 401 or 403.
 */
export async function callWithBearerTokenRefreshOnResponse({
	getToken,
	invalidateToken,
	invoke
}: BearerTokenRefreshDeps<Response>): Promise<Response> {
	const token = await getToken();
	const first = await invoke(token);
	if (first.status !== 401 && first.status !== 403) {
		return first;
	}
	invalidateToken();
	const refreshedToken = await getToken();
	return invoke(refreshedToken);
}

/**
 * Run a bearer-authenticated operation that throws FixtureAuthTokenInvalidError
 * on 401/403, retrying once with a refreshed token. Non-auth errors propagate.
 */
export async function callWithBearerTokenRefreshOnUnauthorizedThrow<T>({
	getToken,
	invalidateToken,
	invoke
}: BearerTokenRefreshDeps<T>): Promise<T> {
	try {
		const token = await getToken();
		return await invoke(token);
	} catch (error) {
		if (!(error instanceof FixtureAuthTokenInvalidError)) {
			throw error;
		}
		invalidateToken();
		const refreshedToken = await getToken();
		return invoke(refreshedToken);
	}
}

type AuthApiResponse = {
	token: string;
	customer_id: string;
};
type JsonHeaders = Record<string, string>;
type RegisterIndexCleanupOptions = {
	deferCleanup?: boolean;
};
type SeedIndexOptions = RegisterIndexCleanupOptions & {
	proofManifestPath?: string;
	settings?: Record<string, unknown>;
};
type WriteSynonymsProofManifestInput = {
	indexName: string;
	objectIDs: string[];
	manifestPath?: string;
};
type SynonymsProofManifest = {
	indexName: string;
	objectIDs: string[];
	cleanup: {
		method: 'DELETE';
		path: string;
		body: { confirm: true };
	};
	generatedAt: string;
	consumed: boolean;
};

export type CreatedFixtureUser = {
	customerId: string;
	token: string;
	email: string;
	password: string;
};

export type FreshSignupIdentity = {
	name: string;
	email: string;
	password: string;
};

type BatchBillingResult = {
	customer_id: string;
	status: string;
	invoice_id: string | null;
	reason: string | null;
};

type BatchBillingResponse = {
	month: string;
	invoices_created: number;
	invoices_skipped: number;
	results: BatchBillingResult[];
};

type ArrangePaidInvoiceForFreshSignupResult = {
	customerId: string;
	invoiceId: string;
	billingMonth: string;
	stagingCustomerId: string;
	stagingInvoiceId: string;
	stagingInvoiceStatus: string;
	stagingInvoicePeriodStart: string;
};

type ArrangeFreshSignupToDashboardResult = {
	prerequisiteFailureMessage: string | null;
};

type TrackCustomerForCleanupFn = (customerId: string) => void;
type ArrangeFreshSignupToDashboardDeps = {
	resolveCleanupCustomerId?: typeof resolveFreshSignupCleanupCustomerId;
	getSessionTokenFromPage?: (page: Page) => Promise<string | null>;
	attemptRemoteFallback?: typeof attemptRemoteSignupFallback;
};

const JSON_CONTENT_TYPE = { 'Content-Type': 'application/json' } as const;

const FRESH_SIGNUP_ARRANGE_SETUP_FAILURE_ALERT_PATTERN =
	/service is unavailable|verify API_URL|verification email temporarily unavailable/i;
const FIXTURE_CUSTOMER_MISSING_LOGIN_ALERT_PATTERN = /invalid (email or password|credentials)/i;
const TRANSIENT_API_MAX_RETRIES = 10;
const IGNORE_TRACKED_FIXTURE_CUSTOMER_ID: TrackCustomerForCleanupFn = () => {};

type ThrowFreshSignupArrangeFailureParams = {
	currentPath: string;
	alertText?: string | null;
	responseStatus?: number;
	responseUrl?: string;
};
type ResolveFreshSignupCleanupCustomerIdParams = {
	sessionToken: string | null;
	currentPath: string;
	responseStatus?: number;
	responseUrl?: string;
	resolveCustomerIdByToken?: (token: string) => Promise<string>;
};
type ThrowBillingPortalArrangeFailureParams = {
	currentPath: string;
	error: unknown;
	responseStatus?: number;
	responseUrl?: string;
};

export function isFreshSignupArrangePrerequisiteFailure(alertText: string): boolean {
	return FRESH_SIGNUP_ARRANGE_SETUP_FAILURE_ALERT_PATTERN.test(alertText.trim());
}

/**
 * TODO: Document throwFreshSignupArrangeFailure.
 */
export function throwFreshSignupArrangeFailure({
	currentPath,
	alertText,
	responseStatus,
	responseUrl
}: ThrowFreshSignupArrangeFailureParams): never {
	const diagnosticEnv = fixtureEnvForFailureDiagnostics();
	throw new Error(
		formatFixtureSetupFailure({
			setupName: 'fresh-signup arrange',
			expectedPath: '/console',
			currentPath,
			apiUrl: diagnosticEnv.apiUrl,
			adminKey: diagnosticEnv.adminKey,
			alertText,
			responseStatus,
			responseUrl
		})
	);
}

/** Resolve cleanup ownership from an authenticated signup session or throw fixture-owned setup errors. */
export async function resolveFreshSignupCleanupCustomerId({
	sessionToken,
	currentPath,
	responseStatus,
	responseUrl,
	resolveCustomerIdByToken = getCustomerIdForToken
}: ResolveFreshSignupCleanupCustomerIdParams): Promise<string> {
	if (!sessionToken) {
		throwFreshSignupArrangeFailure({
			currentPath,
			alertText: 'Sign up reached /console but auth cookie token was missing.',
			responseStatus,
			responseUrl
		});
	}

	try {
		return await resolveCustomerIdByToken(sessionToken);
	} catch (error) {
		throwFreshSignupArrangeFailure({
			currentPath,
			alertText: `Sign up reached /console but fixture could not resolve customer id from auth cookie token: ${setupFailureDetailsFromError(error)}`,
			responseStatus,
			responseUrl
		});
	}
}

/** Throws a fixture-owned fail-closed setup error for billing-portal prerequisites. */
function throwBillingPortalArrangeFailure({
	currentPath,
	error,
	responseStatus,
	responseUrl
}: ThrowBillingPortalArrangeFailureParams): never {
	const diagnosticEnv = fixtureEnvForFailureDiagnostics();
	throw new Error(
		formatFixtureSetupFailure({
			setupName: 'billing-portal arrange',
			expectedPath: '/console/billing',
			currentPath,
			apiUrl: diagnosticEnv.apiUrl,
			adminKey: diagnosticEnv.adminKey,
			alertText: setupFailureDetailsFromError(error),
			responseStatus,
			responseUrl
		})
	);
}

/** Extract a privacy-safe setup failure detail string from arbitrary thrown errors. */
export function setupFailureDetailsFromError(error: unknown): string {
	if (error instanceof Error && error.message.trim()) {
		return redactSensitiveDiagnostics(error.message.trim());
	}
	return redactSensitiveDiagnostics(String(error));
}

function buildJsonRequestInit(method: string, headers: JsonHeaders, body?: unknown): RequestInit {
	return {
		method,
		headers: {
			...JSON_CONTENT_TYPE,
			...headers
		},
		body: body === undefined ? undefined : JSON.stringify(body)
	};
}

async function callJsonApi(
	fetchImpl: typeof fetch,
	apiUrl: string,
	method: string,
	path: string,
	headers: JsonHeaders,
	body?: unknown
): Promise<Response> {
	return fetchImpl(`${apiUrl}${path}`, buildJsonRequestInit(method, headers, body));
}

export function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

function getTransientRetryDelayMs(attempt: number): number {
	return Math.min(2000 * (attempt + 1), 10_000);
}

const REMOTE_SEEDED_INDEX_WRITE_RPS = 100;

function cappedTransientRetryBudgetMs(maxAttempts: number): number {
	return Array.from({ length: maxAttempts }, (_, attempt) =>
		getTransientRetryDelayMs(attempt)
	).reduce((total, delayMs) => total + delayMs, 0);
}

function getRetryDelayMs(attempt: number, retryAfterHeader: string | null): number {
	const retryAfterSeconds = Number(retryAfterHeader ?? '');
	const retryAfterMs =
		Number.isFinite(retryAfterSeconds) && retryAfterSeconds > 0 ? retryAfterSeconds * 1000 : 0;
	return Math.max(retryAfterMs, getTransientRetryDelayMs(attempt));
}

function isTransientAccountLookupFailure(status: number): boolean {
	return status === 429 || status >= 500;
}

function isTransientTransportFailure(error: unknown): boolean {
	if (!(error instanceof Error)) {
		return false;
	}
	const message = error.message.toLowerCase();
	return (
		message.includes('fetch failed') ||
		message.includes('econnrefused') ||
		message.includes('ecconnrefused') ||
		message.includes('socket hang up')
	);
}

function isUnauthorizedExpiredTokenAccountFailure(status: number, failureDetails: string): boolean {
	return status === 401 && /invalid or expired token/i.test(failureDetails);
}

function isTransientSeedIndexTransportFailure(error: unknown): boolean {
	if (!(error instanceof Error)) {
		return false;
	}
	const message = error.message.toLowerCase();
	return (
		message.includes('fetch failed') ||
		message.includes('econnrefused') ||
		message.includes('ecconnrefused') ||
		message.includes('socket hang up') ||
		message.includes('network error')
	);
}

// Keep the setup:user timeout aligned with the helper retry contract so
// Playwright does not abort before fixture bootstrap finishes its own retries.
export const FIXTURE_AUTH_API_RETRY_BUDGET_MS =
	cappedTransientRetryBudgetMs(TRANSIENT_API_MAX_RETRIES);

const STRIPE_DEFAULT_PAYMENT_METHOD_WAIT_MAX_ATTEMPTS = 20;
const INVOICE_STATUS_WAIT_MAX_ATTEMPTS = 90;
const INVOICE_OPEN_WITHOUT_STRIPE_ID_MAX_ATTEMPTS = 12;
const INVOICE_OPEN_WITH_STRIPE_ID_MAX_ATTEMPTS = 46;
const PAID_INVOICE_PROOF_TIMEOUT_BUFFER_MS = 60_000;
const STAGING_LANE_WATCHDOG_TIMEOUT_MS = 480_000;
const PAID_INVOICE_PROOF_WATCHDOG_SAFETY_MARGIN_MS = 30_000;

// Keep the signup-to-paid-invoice spec timeout aligned with its fixture-owned
// Stripe + invoice polling budgets so remote staging failures surface the
// underlying fixture error instead of a generic Playwright timeout.
export const PAID_INVOICE_PROOF_TIMEOUT_MS = Math.min(
	FIXTURE_AUTH_API_RETRY_BUDGET_MS +
		cappedTransientRetryBudgetMs(STRIPE_DEFAULT_PAYMENT_METHOD_WAIT_MAX_ATTEMPTS) +
		cappedTransientRetryBudgetMs(INVOICE_STATUS_WAIT_MAX_ATTEMPTS) +
		PAID_INVOICE_PROOF_TIMEOUT_BUFFER_MS,
	STAGING_LANE_WATCHDOG_TIMEOUT_MS - PAID_INVOICE_PROOF_WATCHDOG_SAFETY_MARGIN_MS
);

type CreateRegisteredUserParams = {
	apiUrl: string;
	email: string;
	password: string;
	name?: string;
	trackCustomerForCleanup: TrackCustomerForCleanupFn;
	fetchImpl?: typeof fetch;
};

type FetchDisposableTenantRateCardSnapshotParams = {
	apiUrl: string;
	adminKey?: string;
	trackCustomerForCleanup: TrackCustomerForCleanupFn;
	fetchImpl?: typeof fetch;
	seed?: string;
};

/**
 * TODO: Document createRegisteredUser.
 */
export async function createRegisteredUser({
	apiUrl,
	email,
	password,
	name,
	trackCustomerForCleanup,
	fetchImpl = fetch
}: CreateRegisteredUserParams): Promise<CreatedFixtureUser> {
	const localApiUrl = requireLoopbackHttpUrl('API_URL', apiUrl);
	const normalizedEmail = requireNonEmptyString(
		email,
		'createRegisteredUser requires non-empty email and password'
	);
	if (!password.trim()) {
		throw new Error('createRegisteredUser requires non-empty email and password');
	}
	const customerName = name?.trim() || `E2E Fixture ${normalizedEmail}`;

	const maxRetries = TRANSIENT_API_MAX_RETRIES;
	for (let attempt = 0; attempt < maxRetries; attempt++) {
		const res = await callJsonApi(
			fetchImpl,
			localApiUrl,
			'POST',
			'/auth/register',
			{},
			{
				name: customerName,
				email: normalizedEmail,
				password
			}
		);
		if (res.status === 429) {
			await sleep(getRetryDelayMs(attempt, res.headers.get('retry-after')));
			continue;
		}
		if (!res.ok) {
			throw new Error(`createUser failed: ${res.status} ${await res.text()}`);
		}
		const data = (await res.json()) as AuthApiResponse;
		trackCustomerForCleanup(data.customer_id);
		return {
			customerId: data.customer_id,
			token: data.token,
			email: normalizedEmail,
			password
		};
	}

	throw new Error('createUser failed: exhausted retries after 429 rate limiting');
}

/**
 * TODO: Document fetchDisposableTenantRateCardSnapshot.
 */
export async function fetchDisposableTenantRateCardSnapshot({
	apiUrl,
	adminKey,
	trackCustomerForCleanup,
	fetchImpl = fetch,
	seed
}: FetchDisposableTenantRateCardSnapshotParams): Promise<MarketingPricingContractSnapshot> {
	const localApiUrl = requireLoopbackHttpUrl('API_URL', apiUrl);
	const snapshotSeed = seed ?? `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
	const disposableUser = await createRegisteredUser({
		apiUrl: localApiUrl,
		email: `pricing-rate-card-${snapshotSeed}@e2e.griddle.test`,
		password: 'TestPassword123!',
		name: `Pricing Rate Card ${snapshotSeed}`,
		trackCustomerForCleanup,
		fetchImpl
	});
	const rateCardResponse = await callJsonApi(
		fetchImpl,
		localApiUrl,
		'GET',
		`/admin/tenants/${encodeURIComponent(disposableUser.customerId)}/rate-card`,
		{ 'x-admin-key': requireAdminApiKey(adminKey) }
	);
	if (!rateCardResponse.ok) {
		throw new Error(
			`fetchDisposableTenantRateCardSnapshot failed: ${rateCardResponse.status} ${await rateCardResponse.text()}`
		);
	}
	const rateCard = (await rateCardResponse.json()) as AdminRateCard;
	return pricingContractSnapshotFromAdminRateCard(rateCard);
}

type LoginAsUserParams = {
	apiUrl: string;
	email: string;
	password: string;
	fetchImpl?: typeof fetch;
};

type LoginAsUserWithKnownMissingUserBootstrapParams = {
	apiUrl: string;
	email: string;
	password: string;
	trackCustomerForCleanup: TrackCustomerForCleanupFn;
	contextLabel: string;
	fetchImpl?: typeof fetch;
	loginAsUserFn?: (params: LoginAsUserParams) => Promise<string>;
	bootstrapFn?: (
		params: BootstrapFixtureUserForKnownLoginFailureParams
	) => Promise<BootstrapFixtureUserForKnownLoginFailureResult>;
};

type BootstrapFixtureUserForKnownLoginFailureParams = {
	apiUrl: string;
	email: string;
	password: string;
	currentPath: string;
	alertText?: string | null;
	responseStatus?: number;
	responseUrl?: string;
	trackCustomerForCleanup?: TrackCustomerForCleanupFn;
	fetchImpl?: typeof fetch;
};

type BootstrapFixtureUserForKnownLoginFailureResult = {
	bootstrapped: boolean;
	loginToken: string | null;
};

type FetchEstimatedBillForTokenParams = {
	apiUrl: string;
	token: string;
	month?: string;
	fetchImpl?: typeof fetch;
};

/**
 * TODO: Document loginAsUser.
 */
export async function loginAsUser({
	apiUrl,
	email,
	password,
	fetchImpl = fetch
}: LoginAsUserParams): Promise<string> {
	const localApiUrl = requireLoopbackHttpUrl('API_URL', apiUrl);
	const maxRetries = TRANSIENT_API_MAX_RETRIES;
	for (let attempt = 0; attempt < maxRetries; attempt++) {
		const res = await callJsonApi(
			fetchImpl,
			localApiUrl,
			'POST',
			'/auth/login',
			{},
			{
				email,
				password
			}
		);
		if (res.status === 429) {
			await sleep(getRetryDelayMs(attempt, res.headers.get('retry-after')));
			continue;
		}
		if (!res.ok) {
			throw new Error(`loginAs failed: ${res.status} ${await res.text()}`);
		}
		const data = (await res.json()) as AuthApiResponse;
		return data.token;
	}

	throw new Error('loginAs failed: exhausted retries after 429 rate limiting');
}

type ArrangeTrackedCustomerSessionForPageParams = {
	page: Page;
	options: ArrangeTrackedCustomerSessionOptions;
	createUser: CreateUserFn;
	loginAs: LoginAsFn;
	verifyCustomerEmail?: (email: string) => Promise<void>;
	forceCustomerEmailUnverified?: (email: string) => Promise<void>;
	setAuthCookie?: (page: Page, token: string) => Promise<void>;
	seed?: string;
};

/** Create a disposable customer, authenticate the page, and return its tracked identity. */
export async function arrangeTrackedCustomerSessionForPage({
	page,
	options,
	createUser,
	loginAs,
	verifyCustomerEmail = verifyTrackedCustomerEmailForRemote,
	forceCustomerEmailUnverified = forceTrackedCustomerEmailUnverifiedForLocal,
	setAuthCookie = setAuthCookieForToken,
	seed = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
}: ArrangeTrackedCustomerSessionForPageParams): Promise<CreatedFixtureUser> {
	const emailPrefix = requireNonEmptyString(
		options.emailPrefix,
		'arrangeTrackedCustomerSession requires a non-empty emailPrefix'
	);
	const password = options.password ?? 'TestPassword123!';
	const email = `${emailPrefix}-${seed}@e2e.griddle.test`;
	const name = options.name?.trim() || `E2E ${emailPrefix} ${seed}`;
	const createdUser = await createUser(email, password, name);
	if (options.verifyEmail !== false) {
		await verifyCustomerEmail(createdUser.email);
	} else {
		await forceCustomerEmailUnverified(createdUser.email);
	}
	const authToken = await loginAs(createdUser.email, password);
	await page.context().clearCookies();
	await setAuthCookie(page, authToken);
	return {
		...createdUser,
		token: authToken,
		password
	};
}

/**
 * Login for fixture flows and recover only the known missing-user seam by
 * bootstrapping the account through the existing helper contract.
 */
export async function loginAsUserWithKnownMissingUserBootstrap({
	apiUrl,
	email,
	password,
	trackCustomerForCleanup,
	contextLabel,
	fetchImpl = fetch,
	loginAsUserFn = loginAsUser,
	bootstrapFn = bootstrapFixtureUserForKnownLoginFailure
}: LoginAsUserWithKnownMissingUserBootstrapParams): Promise<string> {
	try {
		return await loginAsUserFn({ apiUrl, email, password, fetchImpl });
	} catch (error) {
		const loginFailureDetails = setupFailureDetailsFromError(error);
		const loginStatusMatch = loginFailureDetails.match(/\bloginAs failed:\s*(\d{3})\b/i);
		const loginStatus = loginStatusMatch ? Number(loginStatusMatch[1]) : 0;
		if (
			(loginStatus !== 400 && loginStatus !== 401) ||
			!FIXTURE_CUSTOMER_MISSING_LOGIN_ALERT_PATTERN.test(loginFailureDetails)
		) {
			throw error;
		}

		const bootstrap = await bootstrapFn({
			apiUrl,
			email,
			password,
			currentPath: 'http://127.0.0.1:5173/login',
			alertText: 'invalid email or password',
			responseStatus: loginStatus,
			responseUrl: `${apiUrl}/auth/login`,
			trackCustomerForCleanup,
			fetchImpl
		});
		if (bootstrap.loginToken) {
			return bootstrap.loginToken;
		}

		throw new Error(`${contextLabel} failed to re-authenticate after known missing-user bootstrap`);
	}
}

/**
 * TODO: Document isKnownFixtureCustomerMissingLoginFailure.
 */
function isKnownFixtureCustomerMissingLoginFailure({
	currentPath,
	alertText,
	responseStatus,
	responseUrl
}: {
	currentPath: string;
	alertText?: string | null;
	responseStatus?: number;
	responseUrl?: string;
}): boolean {
	const onLoginPage = currentPath.includes('/login');
	const invalidCredentialsMessage = FIXTURE_CUSTOMER_MISSING_LOGIN_ALERT_PATTERN.test(
		alertText?.trim() ?? ''
	);
	// Browser form posts surface `/login` while direct API fixtures surface
	// `/auth/login`; both represent the same invalid-credentials path.
	const knownApiFailureSurface =
		(responseStatus === 400 || responseStatus === 401) &&
		Boolean(responseUrl?.includes('/auth/login') || responseUrl?.includes('/login'));
	const browserOnlyFailureSurface = responseStatus === undefined && responseUrl === undefined;
	return (
		onLoginPage &&
		invalidCredentialsMessage &&
		(knownApiFailureSurface || browserOnlyFailureSurface)
	);
}

/** Bootstrap fixture credentials only when the known missing-user login failure occurs. */
export async function bootstrapFixtureUserForKnownLoginFailure({
	apiUrl,
	email,
	password,
	currentPath,
	alertText,
	responseStatus,
	responseUrl,
	trackCustomerForCleanup = IGNORE_TRACKED_FIXTURE_CUSTOMER_ID,
	fetchImpl = fetch
}: BootstrapFixtureUserForKnownLoginFailureParams): Promise<BootstrapFixtureUserForKnownLoginFailureResult> {
	if (
		!isKnownFixtureCustomerMissingLoginFailure({
			currentPath,
			alertText,
			responseStatus,
			responseUrl
		})
	) {
		return {
			bootstrapped: false,
			loginToken: null
		};
	}

	try {
		await createRegisteredUser({
			apiUrl,
			email,
			password,
			trackCustomerForCleanup,
			fetchImpl
		});
	} catch (error) {
		const details = setupFailureDetailsFromError(error);
		// Idempotency boundary: if another process already created this fixture
		// account, proceed to login instead of failing setup on 409.
		if (!details.includes('createUser failed: 409')) {
			throw error;
		}
	}

	const loginToken = await loginAsUser({
		apiUrl,
		email,
		password,
		fetchImpl
	});

	return {
		bootstrapped: true,
		loginToken
	};
}

/** Fetch the authenticated customer's estimated bill, returning null on 404. */
export async function fetchEstimatedBillForToken({
	apiUrl,
	token,
	month,
	fetchImpl = fetch
}: FetchEstimatedBillForTokenParams): Promise<EstimatedBillResponse | null> {
	const localApiUrl = requireLoopbackHttpUrl('API_URL', apiUrl);
	const query = month ? `?month=${encodeURIComponent(month)}` : '';
	const maxRetries = TRANSIENT_API_MAX_RETRIES;
	for (let attempt = 0; attempt < maxRetries; attempt += 1) {
		const res = await fetchImpl(`${localApiUrl}/billing/estimate${query}`, {
			method: 'GET',
			headers: {
				Authorization: `Bearer ${token}`
			}
		});
		if (res.ok) {
			return (await res.json()) as EstimatedBillResponse;
		}
		// 404 means no estimate data exists yet — genuine absence
		if (res.status === 404) {
			return null;
		}
		if (res.status === 429) {
			await sleep(getRetryDelayMs(attempt, res.headers.get('retry-after')));
			continue;
		}
		// Auth failures (401/403) and server errors (5xx) must surface immediately.
		throw new Error(`/billing/estimate failed: ${res.status} ${await res.text()}`);
	}

	throw new Error('/billing/estimate failed: exhausted retries after 429 rate limiting');
}

type CreateUserFactory = (
	email: string,
	password: string,
	name?: string
) => Promise<CreatedFixtureUser>;

type SeedMultiUserScenarioWithCreateUserParams = {
	createUser: CreateUserFactory;
	password?: string;
	uniqueId?: string;
};

/** Create two uniquely-named users for cross-customer workflows. */
export async function seedMultiUserScenarioWithCreateUser({
	createUser,
	password = 'TestPassword123!',
	uniqueId
}: SeedMultiUserScenarioWithCreateUserParams): Promise<{
	primaryUser: CreatedFixtureUser;
	secondaryUser: CreatedFixtureUser;
}> {
	const seed = uniqueId ?? `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
	const primaryEmail = `multi-user-primary-${seed}@e2e.griddle.test`;
	const secondaryEmail = `multi-user-secondary-${seed}@e2e.griddle.test`;

	const [primaryUser, secondaryUser] = await Promise.all([
		createUser(primaryEmail, password, `Multi User Primary ${seed}`),
		createUser(secondaryEmail, password, `Multi User Secondary ${seed}`)
	]);

	return { primaryUser, secondaryUser };
}

type AdminReactivateCustomerByIdParams = {
	apiUrl: string;
	customerId: string;
	adminKey?: string;
	fetchImpl?: typeof fetch;
};

type AdminSuspendCustomerByIdParams = {
	apiUrl: string;
	customerId: string;
	adminKey?: string;
	fetchImpl?: typeof fetch;
};

/**
 * TODO: Document adminReactivateCustomerById.
 */
export async function adminReactivateCustomerById({
	apiUrl,
	customerId,
	adminKey,
	fetchImpl = fetch
}: AdminReactivateCustomerByIdParams): Promise<void> {
	const localApiUrl = requireLoopbackHttpUrl('API_URL', apiUrl);
	const normalizedCustomerId = requireNonEmptyString(
		customerId,
		'adminReactivateCustomerById requires a non-empty customerId'
	);
	const res = await callJsonApi(
		fetchImpl,
		localApiUrl,
		'POST',
		`/admin/customers/${encodeURIComponent(normalizedCustomerId)}/reactivate`,
		{ 'x-admin-key': requireAdminApiKey(adminKey) }
	);
	if (!res.ok) {
		throw new Error(`adminReactivateCustomer failed: ${res.status} ${await res.text()}`);
	}
}

/**
 * TODO: Document adminSuspendCustomerById.
 */
export async function adminSuspendCustomerById({
	apiUrl,
	customerId,
	adminKey,
	fetchImpl = fetch
}: AdminSuspendCustomerByIdParams): Promise<void> {
	const localApiUrl = requireLoopbackHttpUrl('API_URL', apiUrl);
	const normalizedCustomerId = requireNonEmptyString(
		customerId,
		'adminSuspendCustomerById requires a non-empty customerId'
	);
	const res = await callJsonApi(
		fetchImpl,
		localApiUrl,
		'POST',
		`/admin/customers/${encodeURIComponent(normalizedCustomerId)}/suspend`,
		{ 'x-admin-key': requireAdminApiKey(adminKey) }
	);
	if (!res.ok) {
		throw new Error(`adminSuspendCustomer failed: ${res.status} ${await res.text()}`);
	}
}

/**
 * TODO: Document getAuthToken.
 */
async function getAuthToken(): Promise<string> {
	if (_token) return _token;
	const { email, password } = resolveRequiredFixtureUserCredentials(process.env);
	const maxRetries = 10;
	let lastTransportFailure = '';
	for (let attempt = 0; attempt < maxRetries; attempt++) {
		let res: Response;
		try {
			res = await callJsonApi(
				fetch,
				fixtureEnv.apiUrl,
				'POST',
				'/auth/login',
				{},
				{
					email,
					password
				}
			);
		} catch (error) {
			if (!isTransientTransportFailure(error) || attempt === maxRetries - 1) {
				throw error;
			}
			lastTransportFailure = setupFailureDetailsFromError(error);
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		}
		if (res.status === 429) {
			const retryAfterSeconds = Number(res.headers.get('retry-after') ?? '');
			const retryAfterMs =
				Number.isFinite(retryAfterSeconds) && retryAfterSeconds > 0 ? retryAfterSeconds * 1000 : 0;
			await sleep(Math.max(retryAfterMs, getTransientRetryDelayMs(attempt)));
			continue;
		}
		if (!res.ok) {
			throw new Error(`Auth login failed: ${res.status} ${await res.text()}`);
		}
		const data = (await res.json()) as { token: string };
		_token = data.token;
		return _token;
	}

	if (lastTransportFailure) {
		throw new Error(`Auth login failed after transient transport retries: ${lastTransportFailure}`);
	}
	throw new Error('Auth login failed: exhausted retries after 429 rate limiting');
}

/**
 * TODO: Document getAccountPayloadForTokenWithRetries.
 */
async function getAccountPayloadForTokenWithRetries(
	token: string,
	contextLabel: string
): Promise<{ id?: string; billing_plan?: 'free' | 'shared' }> {
	const maxRetries = TRANSIENT_API_MAX_RETRIES;
	let lastTransientFailure = 'none';
	const currentToken = token;

	for (let attempt = 0; attempt < maxRetries; attempt++) {
		const accountResponse = await callJsonApi(fetch, fixtureEnv.apiUrl, 'GET', '/account', {
			Authorization: `Bearer ${currentToken}`
		});
		if (accountResponse.ok) {
			return (await accountResponse.json()) as { id?: string; billing_plan?: 'free' | 'shared' };
		}

		const failureDetails = `${accountResponse.status} ${await accountResponse.text()}`;
		if (accountResponse.status === 401 || accountResponse.status === 403) {
			throw new FixtureAuthTokenInvalidError(accountResponse.status, failureDetails);
		}
		if (!isTransientAccountLookupFailure(accountResponse.status)) {
			throw new Error(`${contextLabel} failed: ${failureDetails}`);
		}

		lastTransientFailure = failureDetails;
		if (attempt < maxRetries - 1) {
			await sleep(getRetryDelayMs(attempt, accountResponse.headers.get('retry-after')));
		}
	}

	throw new Error(`${contextLabel} failed after transient retries: ${lastTransientFailure}`);
}

function invalidateCachedAuthToken(): void {
	_token = null;
}

/**
 * Resolve the shared fixture customer id, refreshing the cached bearer token
 * once if /account rejects it with 401/403 (e.g. after a local API restart).
 */
async function getCustomerId(): Promise<string> {
	if (_customerId) return _customerId;
	let token = await getAuthToken();
	let accountPayload: { id?: string; billing_plan?: 'free' | 'shared' };

	try {
		accountPayload = await getAccountPayloadForTokenWithRetries(token, 'GET /account');
	} catch (error) {
		if (!(error instanceof Error) || !error.message.includes('GET /account failed: 401')) {
			throw error;
		}

		_token = null;
		token = await getAuthToken();
		accountPayload = await getAccountPayloadForTokenWithRetries(
			token,
			'GET /account after token refresh'
		);
	}

	_customerId = requireNonEmptyString(
		accountPayload.id ?? '',
		'GET /account returned an empty customer id'
	);
	return _customerId;
}

/**
 * Make a bearer-authenticated fixture API call. When no explicit tokenOverride
 * is provided, a stale cached token surfacing as 401/403 is invalidated and the
 * call is retried once with a fresh login token — so every authenticated
 * fixture helper (cleanupStaleFixtureIndexesOnce, waitForSeededIndex, etc.)
 * recovers from in-process token expiry without per-helper logic.
 */
async function apiCall(
	method: string,
	path: string,
	body?: unknown,
	tokenOverride?: string
): Promise<Response> {
	const invokeWithToken = (token: string): Promise<Response> =>
		callJsonApi(fetch, fixtureEnv.apiUrl, method, path, { Authorization: `Bearer ${token}` }, body);

	if (tokenOverride !== undefined) {
		return invokeWithToken(tokenOverride);
	}

	return callWithBearerTokenRefreshOnResponse({
		getToken: getAuthToken,
		invalidateToken: invalidateCachedAuthToken,
		invoke: invokeWithToken
	});
}

/**
 * TODO: Document saveSynonymWithFixtureApi.
 */
async function saveSynonymWithFixtureApi(
	indexName: string,
	synonym: Synonym,
	tokenOverride?: string
): Promise<void> {
	for (let attempt = 0; attempt < 3; attempt += 1) {
		const response = await apiCall(
			'PUT',
			`/indexes/${encodeURIComponent(indexName)}/synonyms/${encodeURIComponent(synonym.objectID)}`,
			synonym,
			tokenOverride
		);
		if (response.ok) {
			return;
		}
		const responseText = await response.text();
		if (
			attempt < 2 &&
			response.status === 400 &&
			responseText.toLowerCase().includes('invalid application-id or api key')
		) {
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		}
		throw new Error(`saveSynonym failed: ${response.status} ${responseText}`);
	}
	throw new Error('saveSynonym failed: retries exhausted');
}

/**
 * TODO: Document getSynonymWithFixtureApi.
 */
async function getSynonymWithFixtureApi(
	indexName: string,
	objectID: string,
	tokenOverride?: string
): Promise<Synonym | null> {
	for (let attempt = 0; attempt < 3; attempt += 1) {
		const response = await apiCall(
			'GET',
			`/indexes/${encodeURIComponent(indexName)}/synonyms/${encodeURIComponent(objectID)}`,
			undefined,
			tokenOverride
		);
		if (response.status === 404) {
			return null;
		}
		if (response.ok) {
			return (await response.json()) as Synonym;
		}
		const responseText = await response.text();
		if (
			attempt < 2 &&
			response.status === 400 &&
			responseText.toLowerCase().includes('invalid application-id or api key')
		) {
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		}
		throw new Error(`getSynonym failed: ${response.status} ${responseText}`);
	}
	throw new Error('getSynonym failed: retries exhausted');
}

/**
 * TODO: Document searchSynonymsWithFixtureApi.
 */
async function searchSynonymsWithFixtureApi(
	indexName: string,
	query = '',
	tokenOverride?: string
): Promise<SynonymSearchResponse> {
	for (let attempt = 0; attempt < 3; attempt += 1) {
		const response = await apiCall(
			'POST',
			`/indexes/${encodeURIComponent(indexName)}/synonyms/search`,
			{
				query,
				page: 0,
				hitsPerPage: 50
			},
			tokenOverride
		);
		if (response.ok) {
			return (await response.json()) as SynonymSearchResponse;
		}
		const responseText = await response.text();
		if (
			attempt < 2 &&
			response.status === 400 &&
			responseText.toLowerCase().includes('invalid application-id or api key')
		) {
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		}
		throw new Error(`searchSynonyms failed: ${response.status} ${responseText}`);
	}
	throw new Error('searchSynonyms failed: retries exhausted');
}

/**
 * TODO: Document clearSynonymsWithFixtureApi.
 */
async function clearSynonymsWithFixtureApi(
	indexName: string,
	tokenOverride?: string
): Promise<void> {
	for (let attempt = 0; attempt < 3; attempt += 1) {
		const response = await apiCall(
			'POST',
			`/indexes/${encodeURIComponent(indexName)}/synonyms/clear`,
			undefined,
			tokenOverride
		);
		if (response.ok) {
			return;
		}
		const responseText = await response.text();
		if (
			attempt < 2 &&
			response.status === 400 &&
			responseText.toLowerCase().includes('invalid application-id or api key')
		) {
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		}
		throw new Error(`clearSynonyms failed: ${response.status} ${responseText}`);
	}
	throw new Error('clearSynonyms failed: retries exhausted');
}

function normalizeProofObjectIDs(objectIDs: string[]): string[] {
	const normalized = objectIDs.map((value) => value.trim()).filter((value) => value.length > 0);
	return Array.from(new Set(normalized));
}

function resolveSynonymsProofManifestPath(manifestPath?: string): string {
	const selectedPath = manifestPath?.trim() || STAGE5_SYNONYMS_PROOF_MANIFEST_PATH;
	return path.resolve(process.cwd(), selectedPath);
}

/**
 * TODO: Document writeSynonymsProofManifest.
 */
async function writeSynonymsProofManifest({
	indexName,
	objectIDs,
	manifestPath
}: WriteSynonymsProofManifestInput): Promise<void> {
	const manifest = {
		indexName,
		objectIDs: normalizeProofObjectIDs(objectIDs),
		cleanup: {
			method: 'DELETE' as const,
			path: `/indexes/${encodeURIComponent(indexName)}`,
			body: { confirm: true as const }
		},
		generatedAt: new Date().toISOString(),
		consumed: false
	} satisfies SynonymsProofManifest;
	const absolutePath = resolveSynonymsProofManifestPath(manifestPath);
	await mkdir(path.dirname(absolutePath), { recursive: true });
	await writeFile(absolutePath, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
}

/**
 * TODO: Document adminApiCall.
 */
async function adminApiCall(method: string, path: string, body?: unknown): Promise<Response> {
	let lastResponse: Response | null = null;
	let lastTransportFailure = '';

	for (let attempt = 0; attempt < 10; attempt += 1) {
		let response: Response;
		try {
			response = await callJsonApi(
				fetch,
				fixtureEnv.apiUrl,
				method,
				path,
				{ 'x-admin-key': requireAdminApiKey(fixtureEnv.adminKey) },
				body
			);
		} catch (error) {
			if (!isTransientTransportFailure(error) || attempt === 9) {
				throw error;
			}
			lastTransportFailure = setupFailureDetailsFromError(error);
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		}

		if (response.status !== 429) {
			return response;
		}

		lastResponse = response;
		if (attempt === 9) {
			break;
		}

		await sleep(getRetryDelayMs(attempt, response.headers.get('retry-after')));
	}

	if (lastTransportFailure) {
		throw new Error(
			`adminApiCall transport retries exhausted for ${method} ${path}: ${lastTransportFailure}`
		);
	}
	return lastResponse ?? new Response('adminApiCall exhausted without a response', { status: 500 });
}

async function raiseRemoteSeededIndexWriteQuota(customerId: string): Promise<void> {
	if (process.env[REMOTE_TARGET_OPT_IN_ENV] !== '1') {
		return;
	}

	const res = await adminApiCall('PUT', `/admin/tenants/${encodeURIComponent(customerId)}/quotas`, {
		max_write_rps: REMOTE_SEEDED_INDEX_WRITE_RPS
	});
	if (res.ok) {
		return;
	}

	throw new Error(`remote seed quota uplift failed: ${res.status} ${await res.text()}`);
}

/**
 * TODO: Document deleteTrackedCustomerForCleanup.
 */
async function deleteTrackedCustomerForCleanup(customerId: string): Promise<void> {
	const response = await adminApiCall('DELETE', `/admin/tenants/${encodeURIComponent(customerId)}`);
	if (response.status === 404) {
		return;
	}
	if (response.status === 401) {
		// Remote staging runs can intentionally omit admin credentials for browser-only
		// seam proofs. Preserve test signal from the assertions and skip tenant teardown
		// instead of failing after spec execution on an admin-only prerequisite.
		return;
	}
	if (!response.ok) {
		throw new Error(
			`tracked fixture customer cleanup failed for ${customerId}: ${response.status} ${await response.text()}`
		);
	}
}

/**
 * TODO: Document seedAdminDeploymentForCustomer.
 */
async function seedAdminDeploymentForCustomer(
	customer: CreatedFixtureUser,
	options?: { region?: string }
): Promise<AdminDeploymentFixture> {
	const region = options?.region ?? fixtureEnv.testRegion;
	const seed = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
	const output = runFixtureSql(
		`
INSERT INTO customer_deployments (
    customer_id,
    node_id,
    region,
    vm_type,
    vm_provider,
    ip_address,
    status,
    provider_vm_id,
    hostname,
    flapjack_url,
    health_status
)
VALUES (
    ${quoteSqlLiteral(customer.customerId)}::uuid,
    ${quoteSqlLiteral(`e2e-admin-deploy-${seed}`)},
    ${quoteSqlLiteral(region)},
    'e2e.small',
    'local',
    '127.0.0.1',
    'running',
    ${quoteSqlLiteral(`local:e2e-admin-deploy-${seed}`)},
    ${quoteSqlLiteral(`e2e-admin-deploy-${seed}`)},
    ${quoteSqlLiteral(fixtureEnv.flapjackUrl)},
    'healthy'
			)
RETURNING id::text || '|' || region || '|' || status;
	`,
		`seed admin deployment for ${customer.customerId}`
	);
	const [id, returnedRegion, status] = output.split('|');
	if (!id || !returnedRegion || !status) {
		throw new Error(`seed admin deployment returned an unexpected row: ${output}`);
	}
	return { id, region: returnedRegion, status };
}

/**
 * TODO: Document runTrackedIndexCleanup.
 */
async function runTrackedIndexCleanup(
	useTrackedIndexCleanup: (
		trackIndexForCleanup: (name: string, options?: RegisterIndexCleanupOptions) => void
	) => Promise<void>,
	deps?: RunTrackedIndexCleanupDeps
): Promise<void> {
	const apiCallForCleanup = deps?.apiCall ?? apiCall;
	const created = new Map<string, RegisterIndexCleanupOptions>();
	await useTrackedIndexCleanup((name: string, options?: RegisterIndexCleanupOptions) => {
		const trimmed = name.trim();
		if (!trimmed) return;
		const previous = created.get(trimmed);
		created.set(trimmed, {
			deferCleanup: Boolean(previous?.deferCleanup || options?.deferCleanup)
		});
	});

	for (const [name, options] of created) {
		if (options.deferCleanup) {
			continue;
		}
		await apiCallForCleanup('DELETE', `/indexes/${encodeURIComponent(name)}`, {
			confirm: true
		}).catch(() => {
			/* ignore — may already be gone */
		});
	}
}

/**
 * TODO: Document runTrackedCustomerCleanup.
 */
async function runTrackedCustomerCleanup(
	useTrackedCustomerCleanup: (
		trackCustomerForCleanup: (customerId: string) => void
	) => Promise<void>,
	deps?: RunTrackedCustomerCleanupDeps
): Promise<void> {
	const deleteCustomerForCleanup =
		deps?.deleteTrackedCustomerForCleanup ?? deleteTrackedCustomerForCleanup;
	const created = new Set<string>();
	let bodyFailure: unknown;
	try {
		await useTrackedCustomerCleanup((customerId: string) => {
			const trimmed = customerId.trim();
			if (!trimmed) return;
			created.add(trimmed);
		});
	} catch (error) {
		bodyFailure = error;
	}

	const cleanupFailures: unknown[] = [];
	for (const customerId of created) {
		try {
			await deleteCustomerForCleanup(customerId);
		} catch (error) {
			cleanupFailures.push(error);
		}
	}

	if (bodyFailure && cleanupFailures.length > 0) {
		throw new AggregateError(
			[bodyFailure, ...cleanupFailures],
			'tracked fixture customer cleanup failed after fixture body failure'
		);
	}
	if (bodyFailure) {
		throw bodyFailure;
	}
	if (cleanupFailures.length === 1) {
		throw cleanupFailures[0];
	}
	if (cleanupFailures.length > 1) {
		throw new AggregateError(cleanupFailures, 'tracked fixture customer cleanup failed');
	}
}

function resetStaleFixtureIndexCleanupState(): void {
	_staleFixtureIndexesCleaned = false;
	_staleFixtureIndexesCleanupCooldownUntil = 0;
}

function getStaleFixtureIndexCleanupState(): StaleFixtureIndexCleanupState {
	return {
		cleaned: _staleFixtureIndexesCleaned,
		cooldownUntil: _staleFixtureIndexesCleanupCooldownUntil
	};
}

export const __fixtureTestSeams = {
	cleanupStaleFixtureIndexesOnce,
	createSeededIndexViaCustomerToken,
	ensureLocalSharedVmInventoryForRegion,
	getStaleFixtureIndexCleanupState,
	resolveFixtureContractPath,
	resetStaleFixtureIndexCleanupState,
	runTrackedCustomerCleanup,
	runTrackedIndexCleanup
};

function isStaleFixtureIndexName(name: string): boolean {
	return STALE_FIXTURE_INDEX_PREFIXES.some((prefix) => name.startsWith(prefix));
}

function assertDeferredProofIndexAvoidsStalePrefixes(name: string): void {
	const stalePrefix = STALE_FIXTURE_INDEX_PREFIXES.find((prefix) => name.startsWith(prefix));
	if (!stalePrefix) {
		return;
	}
	throw new Error(
		`seedIndex deferCleanup index name must avoid stale cleanup prefixes (matched "${stalePrefix}")`
	);
}

/**
 * TODO: Document cleanupStaleFixtureIndexesOnce.
 */
async function cleanupStaleFixtureIndexesOnce(
	options?: CleanupStaleFixtureIndexesOnceOptions
): Promise<void> {
	const forceCleanup = options?.force === true;
	const apiCallForCleanup = options?.apiCall ?? apiCall;
	const now = options?.now ?? Date.now;
	const sleepForCleanup = options?.sleep ?? sleep;
	if (!forceCleanup && _staleFixtureIndexesCleaned) {
		return;
	}
	if (!forceCleanup && now() < _staleFixtureIndexesCleanupCooldownUntil) {
		return;
	}

	let res: Response | null = null;
	for (let attempt = 0; attempt < 4; attempt += 1) {
		res = await apiCallForCleanup('GET', '/indexes');
		if (res.ok) {
			break;
		}
		if (res.status !== 429) {
			throw new Error(
				`cleanupFixtureIndexes failed to list indexes: ${res.status} ${await res.text()}`
			);
		}
		await sleepForCleanup(getRetryDelayMs(attempt, res.headers.get('retry-after')));
	}
	if (!res?.ok) {
		// This cleanup only removes stale local fixtures. If the shared test user is
		// currently throttled, failing the spec here is noisier than tolerating a
		// best-effort miss and letting the real test assertions speak for themselves.
		//
		// Do not mark cleanup as complete when list reads never succeeded: a later
		// fixture call in this worker should retry once throttling clears.
		_staleFixtureIndexesCleanupCooldownUntil = now() + 30_000;
		return;
	}

	const indexes = (await res.json()) as Array<{ name: string }>;
	const staleNames = indexes
		.map((index) => index.name.trim())
		.filter((name) => name && isStaleFixtureIndexName(name));

	// Bounded cleanup window so a single fixture call cannot stall the suite
	// when the shared test user has accumulated many stale indexes — names
	// past the deadline are pushed to unresolvedStaleDeletes and retried on
	// the next fixture call (cleanup stays uncached until convergence).
	const cleanupDeadline =
		now() +
		(forceCleanup
			? FORCE_STALE_INDEX_CLEANUP_DEADLINE_MS
			: PASSIVE_STALE_INDEX_CLEANUP_DEADLINE_MS);
	const unresolvedStaleDeletes: string[] = [];
	for (let staleNameIndex = 0; staleNameIndex < staleNames.length; staleNameIndex += 1) {
		const name = staleNames[staleNameIndex];
		if (now() > cleanupDeadline) {
			unresolvedStaleDeletes.push(...staleNames.slice(staleNameIndex));
			break;
		}
		let deleted = false;
		for (let attempt = 0; attempt < 10; attempt += 1) {
			if (now() > cleanupDeadline) {
				break;
			}
			const deleteRes = await apiCallForCleanup('DELETE', `/indexes/${encodeURIComponent(name)}`, {
				confirm: true
			}).catch(() => null);
			if (!deleteRes) {
				await sleepForCleanup(getTransientRetryDelayMs(attempt));
				continue;
			}
			if (deleteRes.ok || deleteRes.status === 404) {
				deleted = true;
				break;
			}
			if (deleteRes.status !== 429 && deleteRes.status !== 500 && deleteRes.status !== 503) {
				break;
			}
			await sleepForCleanup(getRetryDelayMs(attempt, deleteRes.headers.get('retry-after')));
		}
		if (!deleted) {
			unresolvedStaleDeletes.push(name);
		}
	}

	// Cooldown when deletes don't converge — keeps the fixture retryable across
	// calls without thrashing the API on every call.
	if (unresolvedStaleDeletes.length > 0) {
		_staleFixtureIndexesCleanupCooldownUntil = now() + 30_000;
	}

	if (unresolvedStaleDeletes.length > 0) {
		return;
	}

	_staleFixtureIndexesCleaned = true;
	_staleFixtureIndexesCleanupCooldownUntil = 0;
}

/**
 * TODO: Document waitForSeededIndex.
 */
async function waitForSeededIndex(name: string, tokenOverride?: string): Promise<void> {
	const maxAttempts = 60;
	const pollIntervalMs = 500;
	let lastStatus: number | null = null;

	for (let attempt = 0; attempt < maxAttempts; attempt++) {
		const res = await apiCall(
			'GET',
			`/indexes/${encodeURIComponent(name)}`,
			undefined,
			tokenOverride
		);
		if (res.ok) {
			return;
		}
		lastStatus = res.status;
		if (res.status !== 404 && res.status !== 429 && res.status !== 500) {
			throw new Error(`seedIndex readiness check failed: ${res.status} ${await res.text()}`);
		}
		// Back off longer on rate-limit responses to avoid exhausting the window
		const delay = res.status === 429 ? getTransientRetryDelayMs(attempt) : pollIntervalMs;
		await sleep(delay);
	}

	throw new Error(
		`seedIndex readiness check timed out for index "${name}" (last status: ${lastStatus ?? 'none'})`
	);
}

/** Apply deterministic settings to a seeded index before browser tests load it. */
async function updateSeededIndexSettings(
	name: string,
	settings: Record<string, unknown>,
	tokenOverride?: string
): Promise<void> {
	const maxAttempts = 8;
	let lastFailure = 'none';

	for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
		const response = await apiCall(
			'PUT',
			`/indexes/${encodeURIComponent(name)}/settings`,
			settings,
			tokenOverride
		);
		if (response.ok) {
			return;
		}

		const body = await response.text();
		lastFailure = `${response.status} ${body}`;
		if (response.status !== 404 && response.status !== 429 && response.status !== 500) {
			throw new Error(`seedIndex settings failed: ${lastFailure}`);
		}
		await sleep(getTransientRetryDelayMs(attempt));
	}

	throw new Error(`seedIndex settings failed after transient retries: ${lastFailure}`);
}

/**
 * TODO: Document assertIndexNeverBecomesReadable.
 */
async function assertIndexNeverBecomesReadable(name: string): Promise<void> {
	const maxAttempts = 60;
	const pollIntervalMs = 500;

	for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
		const response = await apiCall('GET', `/indexes/${encodeURIComponent(name)}`);
		if (response.ok) {
			throw new Error(
				`deferred proof absence check failed: index "${name}" became readable (${response.status})`
			);
		}
		if (response.status !== 404 && response.status !== 429 && response.status !== 500) {
			throw new Error(
				`deferred proof absence check failed: ${response.status} ${await response.text()}`
			);
		}
		const delay = response.status === 429 ? getTransientRetryDelayMs(attempt) : pollIntervalMs;
		await sleep(delay);
	}

	// Terminate with a concrete not-found read so transient throttling cannot
	// masquerade as proof that the index truly stayed absent.
	for (let attempt = 0; attempt < 10; attempt += 1) {
		const response = await apiCall('GET', `/indexes/${encodeURIComponent(name)}`);
		if (response.status === 404) {
			return;
		}
		if (response.status === 429 || response.status === 500) {
			await sleep(getRetryDelayMs(attempt, response.headers.get('retry-after')));
			continue;
		}
		if (response.ok) {
			throw new Error(
				`deferred proof absence check failed: index "${name}" became readable (${response.status})`
			);
		}
		throw new Error(
			`deferred proof absence check failed: ${response.status} ${await response.text()}`
		);
	}

	throw new Error(
		`deferred proof absence check failed: could not confirm 404 for index "${name}" after transient retries`
	);
}

function isIndexLimitReachedFailure(status: number, body: string): boolean {
	return status === 400 && body.toLowerCase().includes('index limit reached');
}

/**
 * TODO: Document createSeededIndex.
 */
async function createSeededIndex(
	customerId: string,
	name: string,
	region: string,
	flapjackUrl: string,
	customerToken?: string
): Promise<void> {
	// In remote-target mode the deployed API allocates a VM from its own
	// vm_inventory via the customer-auth POST /indexes route. The admin
	// seed path (which body-passes flapjack_url) is the wrong tool here —
	// the local test host's flapjack URL is not routable inside staging's
	// VPC, and the staging shared flapjack is http-only so the loopback
	// validator rejects it. The customer-auth path goes through the real
	// allocator which links a real VM, so synonyms/documents/api-keys
	// proxy calls work. Email-verified state is already arranged by
	// auth.setup → verifyFreshSignupEmail.
	if (process.env[REMOTE_TARGET_OPT_IN_ENV] === '1') {
		if (customerToken) {
			await createSeededIndexViaCustomerToken(name, region, customerToken);
		} else {
			await createSeededIndexForCurrentCustomer(name, region);
		}
		return;
	}
	const safeFlapjackUrl = requireLoopbackHttpUrl('FLAPJACK_URL', flapjackUrl);
	const maxRetries = 6;
	let lastFailure = 'none';
	let fallbackToken = customerToken;

	for (let attempt = 0; attempt < maxRetries; attempt++) {
		const res = await adminApiCall(
			'POST',
			`/admin/tenants/${encodeURIComponent(customerId)}/indexes`,
			{
				name,
				region,
				flapjack_url: safeFlapjackUrl
			}
		);
		if (res.ok) {
			return;
		}

		const body = await res.text();
		lastFailure = `${res.status} ${body}`;

		// A retry can race with a previous attempt that actually created the
		// index before the server surfaced a transient failure to the client.
		if (res.status === 409 && attempt > 0) {
			return;
		}

		// Shared-host Playwright runs can restart the API with a different
		// admin key mid-suite. Signal "invalid admin key" so the seedIndex
		// factory can fall back to customer-auth creation; only attempt the
		// in-function fallback when seedCustomerIndex explicitly passed its
		// own token (it owns a per-customer create flow and does not want
		// the factory-level fallback to a different customer's auth).
		if (res.status === 401 && !fallbackToken) {
			throw new Error(`createSeededIndex: invalid admin key (${lastFailure})`);
		}
		if (res.status === 401 && fallbackToken) {
			const fallbackResponse = await callJsonApi(
				fetch,
				fixtureEnv.apiUrl,
				'POST',
				'/indexes',
				{ Authorization: `Bearer ${fallbackToken}` },
				{ name, region }
			);
			if (fallbackResponse.ok) {
				return;
			}
			const fallbackBody = await fallbackResponse.text();
			lastFailure = `admin 401; customer fallback ${fallbackResponse.status} ${fallbackBody}`;
			if (fallbackResponse.status === 409) {
				return;
			}
			if (fallbackResponse.status === 401 || fallbackResponse.status === 403) {
				_token = null;
				fallbackToken = await getAuthToken();
				await sleep(getTransientRetryDelayMs(attempt));
				continue;
			}
			if (isIndexLimitReachedFailure(fallbackResponse.status, fallbackBody)) {
				await cleanupStaleFixtureIndexesOnce({ force: true });
				await sleep(getTransientRetryDelayMs(attempt));
				continue;
			}
			if (
				fallbackResponse.status !== 429 &&
				fallbackResponse.status !== 500 &&
				fallbackResponse.status !== 503
			) {
				throw new Error(`seedIndex failed: ${lastFailure}`);
			}
		} else if (isIndexLimitReachedFailure(res.status, body)) {
			await cleanupStaleFixtureIndexesOnce({ force: true });
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		} else if (res.status !== 401 && res.status !== 429 && res.status !== 500) {
			throw new Error(`seedIndex failed: ${lastFailure}`);
		}

		await sleep(getTransientRetryDelayMs(attempt));
	}

	throw new Error(`seedIndex failed after transient create retries: ${lastFailure}`);
}

/**
 * TODO: Document createSeededIndexViaCustomerToken.
 */
async function createSeededIndexViaCustomerToken(
	name: string,
	region: string,
	customerToken: string
): Promise<void> {
	const maxRetries = 6;
	let lastFailure = 'none';

	for (let attempt = 0; attempt < maxRetries; attempt++) {
		const res = await callJsonApi(
			fetch,
			fixtureEnv.apiUrl,
			'POST',
			'/indexes',
			{ Authorization: `Bearer ${customerToken}` },
			{ name, region }
		);
		if (res.ok || res.status === 409) {
			return;
		}

		const body = await res.text();
		lastFailure = `${res.status} ${body}`;
		if (isIndexLimitReachedFailure(res.status, body)) {
			await cleanupStaleFixtureIndexesOnce({ force: true });
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		}
		if (res.status !== 429 && res.status !== 500 && res.status !== 503) {
			throw new Error(`seedIndex failed: ${lastFailure}`);
		}

		await sleep(getTransientRetryDelayMs(attempt));
	}

	throw new Error(`seedIndex failed after transient create retries: ${lastFailure}`);
}

type TrackedCustomerIndex = {
	token: string;
	name: string;
	deferCleanup: boolean;
};

type SeedCustomerIndexForFixtureParams = {
	customer: CreatedFixtureUser;
	name: string;
	region: string;
	flapjackUrl: string;
	options?: SeedIndexOptions;
	trackCreatedIndex: (entry: TrackedCustomerIndex) => void;
};

type SeedCustomerIndexForFixtureDeps = {
	createSeededIndexFn?: typeof createSeededIndex;
	waitForSeededIndexFn?: typeof waitForSeededIndex;
	updateSeededIndexSettingsFn?: typeof updateSeededIndexSettings;
	raiseRemoteSeededIndexWriteQuotaFn?: typeof raiseRemoteSeededIndexWriteQuota;
	writeSynonymsProofManifestFn?: typeof writeSynonymsProofManifest;
};

/** Seed an index owned by an explicit disposable customer and register fixture cleanup. */
export async function seedCustomerIndexForFixture(
	{
		customer,
		name,
		region,
		flapjackUrl,
		options,
		trackCreatedIndex
	}: SeedCustomerIndexForFixtureParams,
	{
		createSeededIndexFn = createSeededIndex,
		waitForSeededIndexFn = waitForSeededIndex,
		updateSeededIndexSettingsFn = updateSeededIndexSettings,
		raiseRemoteSeededIndexWriteQuotaFn = raiseRemoteSeededIndexWriteQuota,
		writeSynonymsProofManifestFn = writeSynonymsProofManifest
	}: SeedCustomerIndexForFixtureDeps = {}
): Promise<void> {
	const deferCleanup = Boolean(options?.deferCleanup);
	if (deferCleanup) {
		assertDeferredProofIndexAvoidsStalePrefixes(name);
	}

	await createSeededIndexFn(customer.customerId, name, region, flapjackUrl, customer.token);
	trackCreatedIndex({ token: customer.token, name, deferCleanup });
	await waitForSeededIndexFn(name, customer.token);
	if (options?.settings) {
		await updateSeededIndexSettingsFn(name, options.settings, customer.token);
	}
	await raiseRemoteSeededIndexWriteQuotaFn(customer.customerId);
	if (deferCleanup) {
		await writeSynonymsProofManifestFn({
			indexName: name,
			objectIDs: [],
			manifestPath: options?.proofManifestPath
		});
	}
}

/**
 * TODO: Document createSeededIndexForCurrentCustomer.
 */
async function createSeededIndexForCurrentCustomer(name: string, region: string): Promise<void> {
	const maxRetries = 6;
	let lastFailure = 'none';

	for (let attempt = 0; attempt < maxRetries; attempt++) {
		const res = await apiCall('POST', '/indexes', {
			name,
			region
		});
		if (res.ok || res.status === 409) {
			return;
		}

		const body = await res.text();
		lastFailure = `${res.status} ${body}`;
		if (isUnauthorizedExpiredTokenAccountFailure(res.status, lastFailure)) {
			_token = null;
			continue;
		}
		if (isIndexLimitReachedFailure(res.status, body)) {
			await cleanupStaleFixtureIndexesOnce({ force: true });
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		}
		if (res.status !== 429 && res.status !== 500) {
			throw new Error(`seedIndex failed: ${lastFailure}`);
		}

		await sleep(getTransientRetryDelayMs(attempt));
	}

	throw new Error(`seedIndex failed after transient create retries: ${lastFailure}`);
}

const RECOMMENDATION_FIXTURE_FACET_NAME = 'category';
const RECOMMENDATION_FIXTURE_FACET_VALUE = 'language';
const RECOMMENDATION_FIXTURE_MISSING_FACET_VALUE = 'no-matches-category';

/**
 * TODO: Document getCurrentBillingPlan.
 */
async function getCurrentBillingPlan(tokenOverride?: string): Promise<'free' | 'shared'> {
	for (let attempt = 0; attempt < TRANSIENT_API_MAX_RETRIES; attempt += 1) {
		const res = await apiCall('GET', '/account', undefined, tokenOverride);
		if (res.status === 429) {
			await sleep(getRetryDelayMs(attempt, res.headers.get('retry-after')));
			continue;
		}
		if (!res.ok) {
			throw new Error(`GET /account failed: ${res.status} ${await res.text()}`);
		}
		const data = (await res.json()) as { billing_plan: 'free' | 'shared' };
		return data.billing_plan;
	}

	throw new Error('GET /account failed: exhausted retries after 429 rate limiting');
}

async function updateBillingPlan(
	plan: 'free' | 'shared',
	customerIdOverride?: string
): Promise<void> {
	const customerId = customerIdOverride ?? (await getCustomerId());
	const res = await adminApiCall('PUT', `/admin/tenants/${encodeURIComponent(customerId)}`, {
		billing_plan: plan
	});
	if (!res.ok) {
		throw new Error(`setBillingPlan failed: ${res.status} ${await res.text()}`);
	}
}

type ArrangeBillingPortalCustomerResult = CreatedFixtureUser & {
	stripeCustomerId: string;
	defaultPaymentMethodId: string;
	nonDefaultPaymentMethodId: string;
	expectedDefaultPaymentMethodId: string;
};

type ArrangeBillingPortalCustomerParams = {
	trackCustomerForCleanup: TrackCustomerForCleanupFn;
};

type ArrangePaidInvoiceForFreshSignupParams = {
	email: string;
	password: string;
	trackCustomerForCleanup: TrackCustomerForCleanupFn;
};

type MailpitSearchResponse = {
	messages?: Array<{ ID?: string; id?: string }>;
	messages_count?: number;
	total?: number;
};

export const LOCAL_AUTO_VERIFIED_TOKEN_PREFIX = 'local-auto-verified-';

function buildFreshSignupIdentity(seed?: string): FreshSignupIdentity {
	const identitySeed = seed?.trim() || `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
	return {
		name: `Signup Lane ${identitySeed}`,
		email: `signup-paid-${identitySeed}@e2e.griddle.test`,
		password: 'TestPassword123!'
	};
}

/**
 * TODO: Document arrangeFreshSignupToDashboardWithFixtureFallback.
 */
export async function arrangeFreshSignupToDashboardWithFixtureFallback(
	{
		page,
		signup,
		createUser,
		trackCustomerForCleanup
	}: {
		page: Page;
		signup: FreshSignupIdentity;
		createUser: CreateUserFn;
		trackCustomerForCleanup: TrackCustomerForCleanupFn;
	},
	{
		resolveCleanupCustomerId = resolveFreshSignupCleanupCustomerId,
		getSessionTokenFromPage = getAuthCookieTokenFromPage,
		attemptRemoteFallback = attemptRemoteSignupFallback
	}: ArrangeFreshSignupToDashboardDeps = {}
): Promise<ArrangeFreshSignupToDashboardResult> {
	await page.goto('/signup');
	await page.getByLabel('Name').fill(signup.name);
	await page.getByLabel('Email').fill(signup.email);
	await page.getByLabel('Password', { exact: true }).fill(signup.password);
	await page.getByLabel('Confirm Password').fill(signup.password);

	const signupResponsePromise = page
		.waitForResponse(
			(response) => response.request().method() === 'POST' && response.url().includes('/signup'),
			{ timeout: 20_000 }
		)
		.catch(() => null);
	await page.getByRole('button', { name: 'Sign Up' }).click();

	const signupAlert = page.getByRole('alert');
	await Promise.race([
		page.waitForURL(/\/console/, { timeout: 20_000 }),
		signupAlert.waitFor({ state: 'visible', timeout: 20_000 })
	]).catch(() => undefined);

	if (/\/console/.test(page.url())) {
		const signupResponse = await signupResponsePromise;
		const customerId = await resolveCleanupCustomerId({
			sessionToken: await getSessionTokenFromPage(page),
			currentPath: page.url(),
			responseStatus: signupResponse?.status(),
			responseUrl: signupResponse?.url()
		});
		trackCustomerForCleanup(customerId);
		return { prerequisiteFailureMessage: null };
	}

	const signupResponse = await signupResponsePromise;
	const alertVisible = await signupAlert.isVisible().catch(() => false);
	const alertText = alertVisible ? ((await signupAlert.textContent())?.trim() ?? '') : '';
	let fallbackSucceeded = false;
	let fallbackErrorDetail: string | null = null;
	try {
		fallbackSucceeded = await attemptRemoteFallback({
			page,
			email: signup.email,
			password: signup.password,
			name: signup.name,
			createUser,
			remoteTargetOptInEnv: REMOTE_TARGET_OPT_IN_ENV
		});
	} catch (error) {
		fallbackErrorDetail = setupFailureDetailsFromError(error);
	}

	if (fallbackSucceeded) {
		return { prerequisiteFailureMessage: null };
	}
	if (fallbackErrorDetail) {
		throwFreshSignupArrangeFailure({
			currentPath: page.url(),
			alertText: [
				alertText || 'Sign up did not reach /console and no alert was visible within 20 seconds.',
				`Remote signup fallback failed: ${fallbackErrorDetail}`
			].join(' | '),
			responseStatus: signupResponse?.status(),
			responseUrl: signupResponse?.url()
		});
	}

	if (isFreshSignupArrangePrerequisiteFailure(alertText)) {
		return {
			prerequisiteFailureMessage: alertText || 'unknown alert'
		};
	}

	throwFreshSignupArrangeFailure({
		currentPath: page.url(),
		alertText:
			alertText || 'Sign up did not reach /console and no alert was visible within 20 seconds.',
		responseStatus: signupResponse?.status(),
		responseUrl: signupResponse?.url()
	});
}

async function getAuthCookieTokenFromPage(page: Page): Promise<string | null> {
	const sessionCookie = (await page.context().cookies()).find(
		(cookie) => cookie.name === AUTH_COOKIE && cookie.value.trim().length > 0
	);
	return sessionCookie?.value.trim() || null;
}

function currentUtcBillingMonth(now = new Date()): string {
	const month = String(now.getUTCMonth() + 1).padStart(2, '0');
	return `${now.getUTCFullYear()}-${month}`;
}

/**
 * TODO: Document getMailpitApiUrl.
 */
function getMailpitApiUrl(): string {
	const configuredMailpitApiUrl = process.env.MAILPIT_API_URL?.trim();
	if (!configuredMailpitApiUrl) {
		const diagnosticEnv = fixtureEnvForFailureDiagnostics();
		throw new Error(
			formatFixtureSetupFailure({
				setupName: 'fresh-signup mailpit setup',
				expectedPath: 'MAILPIT_API_URL',
				currentPath: '(env:MAILPIT_API_URL)',
				apiUrl: diagnosticEnv.apiUrl,
				adminKey: diagnosticEnv.adminKey,
				alertText: 'MAILPIT_API_URL must be set for fresh-signup verification checks'
			})
		);
	}
	return requireLoopbackHttpUrl('MAILPIT_API_URL', configuredMailpitApiUrl);
}

function extractMailpitMessageId(rawMessage: unknown): string | null {
	if (!rawMessage || typeof rawMessage !== 'object') {
		return null;
	}

	const record = rawMessage as { ID?: unknown; id?: unknown };
	const id = record.ID ?? record.id;
	if (typeof id !== 'string' || !id.trim()) {
		return null;
	}

	return id;
}

function extractVerificationTokenFromMailpitPayload(payload: unknown): string | null {
	const payloadText = JSON.stringify(payload ?? {});
	const patterns = [/\/verify-email\/([A-Za-z0-9_-]+)/, /verify-email[?&]token=([A-Za-z0-9_-]+)/];

	for (const pattern of patterns) {
		const match = pattern.exec(payloadText);
		const token = match?.[1];
		if (token) {
			return token;
		}
	}

	return null;
}

async function fetchMailpitMessageIds(query: string): Promise<string[]> {
	const mailpitApiUrl = getMailpitApiUrl();
	const searchResponse = await fetch(
		`${mailpitApiUrl}/api/v1/search?query=${encodeURIComponent(query)}`
	);
	if (!searchResponse.ok) {
		throw new Error(
			`Mailpit search failed: ${searchResponse.status} ${await searchResponse.text()}`
		);
	}

	const payload = (await searchResponse.json()) as MailpitSearchResponse;
	const messages = Array.isArray(payload.messages) ? payload.messages : [];
	return messages.map(extractMailpitMessageId).filter((id): id is string => id !== null);
}

async function fetchMailpitMessagePayload(messageId: string): Promise<unknown> {
	const mailpitApiUrl = getMailpitApiUrl();
	const messageResponse = await fetch(
		`${mailpitApiUrl}/api/v1/message/${encodeURIComponent(messageId)}`
	);
	if (!messageResponse.ok) {
		throw new Error(
			`Mailpit message fetch failed for ${messageId}: ${messageResponse.status} ${await messageResponse.text()}`
		);
	}
	return messageResponse.json();
}

type FindMailpitTokenParams = {
	email: string;
	missingEmailMessage: string;
	extractToken: (payload: unknown) => string | null;
	setupName: string;
	expectedPath: string;
	missingTokenMessage: string;
};

/**
 * TODO: Document findTokenViaMailpit.
 */
async function findTokenViaMailpit({
	email,
	missingEmailMessage,
	extractToken,
	setupName,
	expectedPath,
	missingTokenMessage
}: FindMailpitTokenParams): Promise<string> {
	const normalizedEmail = requireNonEmptyString(email, missingEmailMessage);
	const maxAttempts = 30;
	const query = `to:${normalizedEmail}`;

	for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
		const messageIds = await fetchMailpitMessageIds(query).catch(() => []);
		for (const messageId of messageIds) {
			const payload = await fetchMailpitMessagePayload(messageId).catch(() => null);
			const token = extractToken(payload);
			if (token) {
				return token;
			}
		}

		await sleep(1000);
	}

	const diagnosticEnv = fixtureEnvForFailureDiagnostics();
	throw new Error(
		formatFixtureSetupFailure({
			setupName,
			expectedPath,
			currentPath: '(mailpit search)',
			apiUrl: diagnosticEnv.apiUrl,
			adminKey: diagnosticEnv.adminKey,
			alertText: `${missingTokenMessage} for ${normalizedEmail} after ${maxAttempts}s`
		})
	);
}

/**
 * TODO: Document findVerificationTokenViaMailpit.
 */
export async function findVerificationTokenViaMailpit(email: string): Promise<string> {
	return findTokenViaMailpit({
		email,
		missingEmailMessage: 'findVerificationTokenViaMailpit requires a non-empty email',
		extractToken: extractVerificationTokenFromMailpitPayload,
		setupName: 'fresh-signup email verification token lookup',
		expectedPath: '/verify-email/{token}',
		missingTokenMessage: 'No verification token found in Mailpit'
	});
}

/**
 * TODO: Document extractResetTokenFromMailpitPayload.
 */
export function extractResetTokenFromMailpitPayload(payload: unknown): string | null {
	const payloadText = JSON.stringify(payload ?? {});
	const patterns = [
		/\/reset-password\/([A-Za-z0-9_-]+)/,
		/reset-password[?&]token=([A-Za-z0-9_-]+)/
	];

	for (const pattern of patterns) {
		const match = pattern.exec(payloadText);
		const token = match?.[1];
		if (token) {
			return token;
		}
	}

	return null;
}

/**
 * TODO: Document findResetTokenViaMailpit.
 */
export async function findResetTokenViaMailpit(email: string): Promise<string> {
	return findTokenViaMailpit({
		email,
		missingEmailMessage: 'findResetTokenViaMailpit requires a non-empty email',
		extractToken: extractResetTokenFromMailpitPayload,
		setupName: 'forgot-password reset token lookup',
		expectedPath: '/reset-password/{token}',
		missingTokenMessage: 'No reset token found in Mailpit'
	});
}

/**
 * Look up the verification token for a freshly-signed-up customer.
 *
 * Local lane: token is read from Mailpit (the local SMTP catcher).
 *
 * LB-2/LB-3 remote lane: when PLAYWRIGHT_TARGET_REMOTE=1, Mailpit doesn't
 * exist (staging uses real SES). The token is instead read directly from
 * the staging customers table via SSM-exec'd psql on the EC2 host. See
 * web/tests/fixtures/staging_db_lookup.ts and LB-2/LB-3 in LAUNCH.md.
 */
async function findFreshSignupVerificationToken(email: string): Promise<string> {
	// Read the opt-in flag through the canonical constant exported by
	// playwright.config.contract.ts so the env var name has exactly one
	// definition site (SSoT). The harness, the loopback guard, and this
	// dispatcher all reference the same source of truth.
	if (process.env[REMOTE_TARGET_OPT_IN_ENV] === '1') {
		return findVerificationTokenViaStagingSsm(email);
	}
	return findVerificationTokenViaMailpit(email);
}

/**
 * TODO: Document loginConfirmsFreshSignupAlreadyVerified.
 */
async function loginConfirmsFreshSignupAlreadyVerified(
	email: string,
	password: string | undefined
): Promise<boolean> {
	if (!password?.trim()) {
		return false;
	}

	for (let attempt = 0; attempt < TRANSIENT_API_MAX_RETRIES; attempt += 1) {
		const loginResponse = await callJsonApi(
			fetch,
			fixtureEnv.apiUrl,
			'POST',
			'/auth/login',
			{},
			{ email, password }
		);
		if (loginResponse.status === 429) {
			await sleep(getRetryDelayMs(attempt, loginResponse.headers.get('retry-after')));
			continue;
		}
		return loginResponse.ok;
	}
	return false;
}

/**
 * TODO: Document resolveFreshSignupVerificationTokenOrAutoVerifiedSentinel.
 */
async function resolveFreshSignupVerificationTokenOrAutoVerifiedSentinel(
	email: string,
	password: string | undefined
): Promise<string> {
	if (
		process.env[REMOTE_TARGET_OPT_IN_ENV] !== '1' &&
		(await loginConfirmsFreshSignupAlreadyVerified(email, password))
	) {
		return `${LOCAL_AUTO_VERIFIED_TOKEN_PREFIX}${Date.now()}`;
	}

	try {
		return await findFreshSignupVerificationToken(email);
	} catch (error) {
		if (
			process.env[REMOTE_TARGET_OPT_IN_ENV] !== '1' &&
			(await loginConfirmsFreshSignupAlreadyVerified(email, password))
		) {
			return `${LOCAL_AUTO_VERIFIED_TOKEN_PREFIX}${Date.now()}`;
		}
		throw error;
	}
}

/**
 * TODO: Document completeFreshSignupEmailVerificationViaRoute.
 */
async function completeFreshSignupEmailVerificationViaRoute(
	page: Page,
	email: string,
	password?: string
): Promise<{ verificationToken: string }> {
	try {
		const verificationToken = await resolveFreshSignupVerificationTokenOrAutoVerifiedSentinel(
			email,
			password
		);
		if (verificationToken.startsWith(LOCAL_AUTO_VERIFIED_TOKEN_PREFIX)) {
			// The locally spawned Playwright API intentionally auto-verifies
			// signups. There is no email token to replay, so assert the browser
			// route's consumed/invalid-token result instead of polling Mailpit.
			await page.context().clearCookies();
			await page.goto(`/verify-email/${verificationToken}`);
			await expect(
				page.getByRole('heading', { name: 'We could not verify your email' })
			).toBeVisible({
				timeout: 10_000
			});
			return { verificationToken };
		}
		// Remote browser lanes can target a deployed frontend host whose
		// verify-email route is not guaranteed to consume staging tokens via the
		// same API origin as fixtureEnv.apiUrl. In remote mode, consume the
		// token through the staging API seam first, then let specs assert browser
		// replay behavior on /verify-email/{token}.
		if (process.env[REMOTE_TARGET_OPT_IN_ENV] === '1') {
			for (let attempt = 0; attempt < TRANSIENT_API_MAX_RETRIES; attempt += 1) {
				const verifyResponse = await callJsonApi(
					fetch,
					fixtureEnv.apiUrl,
					'POST',
					'/auth/verify-email',
					{},
					{ token: verificationToken }
				);
				if (verifyResponse.status === 429) {
					await sleep(getRetryDelayMs(attempt, verifyResponse.headers.get('retry-after')));
					continue;
				}
				if (!verifyResponse.ok) {
					throw new Error(
						`staging API verify-email failed: ${verifyResponse.status} ${await verifyResponse.text()}`
					);
				}
				await page.context().clearCookies();
				// Cooldown before the spec navigates to /verify-email/{token} in the
				// browser — the SvelteKit server makes a second API call and upstream
				// rate limiters (Cloudflare) can reject it if it arrives too soon.
				await sleep(3000);
				return { verificationToken };
			}
			throw new Error('staging API verify-email failed: exhausted retries after 429 rate limiting');
		}

		// Public auth pages redirect authenticated users to /console, so clear
		// auth cookies before exercising the verify-email success contract.
		await page.context().clearCookies();
		await page.goto(`/verify-email/${verificationToken}`);
		await expect(page.getByRole('heading', { name: 'Email Verified' })).toBeVisible({
			timeout: 30_000
		});
		return { verificationToken };
	} catch (error) {
		const diagnosticEnv = fixtureEnvForFailureDiagnostics();
		throw new Error(
			formatFixtureSetupFailure({
				setupName: 'fresh-signup email verification replay setup',
				expectedPath: '/verify-email/{token}',
				currentPath: page.url() || '(no browser url)',
				apiUrl: diagnosticEnv.apiUrl,
				adminKey: diagnosticEnv.adminKey,
				alertText: setupFailureDetailsFromError(error)
			})
		);
	}
}

/**
 * TODO: Document getCustomerIdForToken.
 */
async function getCustomerIdForToken(token: string): Promise<string> {
	const accountPayload = await getAccountPayloadForTokenWithRetries(token, 'getCustomerIdForToken');
	return requireNonEmptyString(
		accountPayload.id ?? '',
		'getCustomerIdForToken received an empty customer id'
	);
}

/**
 * TODO: Document syncStripeCustomer.
 */
async function syncStripeCustomer(customerId: string, contextLabel: string): Promise<string> {
	const stripeSync = await adminApiCall(
		'POST',
		`/admin/customers/${encodeURIComponent(customerId)}/sync-stripe`
	);
	if (!stripeSync.ok) {
		throw new Error(
			`${contextLabel} failed to sync stripe customer: ${stripeSync.status} ${await stripeSync.text()}`
		);
	}

	const stripeSyncPayload = (await stripeSync.json()) as { stripe_customer_id?: string };
	if (!stripeSyncPayload.stripe_customer_id) {
		throw new Error(`${contextLabel} failed: stripe sync returned no stripe_customer_id`);
	}
	return stripeSyncPayload.stripe_customer_id;
}

/**
 * Attach Stripe's well-known `pm_card_visa` test payment method to the given
 * Stripe customer and set it as the customer's default `invoice_settings`
 * payment method. Returns the attached PaymentMethod id.
 *
 * Why this exists as a shared helper: both `arrangeBillingPortalCustomer`
 * (LB-3 lane) and `arrangePaidInvoiceForFreshSignup` (LB-2 lane) need a
 * disposable test customer with a default PM so Stripe can auto-charge
 * the invoice in `charge_automatically` mode. Previously only the LB-3
 * fixture attached a PM; the LB-2 fixture skipped this step and the
 * resulting invoice sat in `open` state forever, timing out
 * `waitForInvoicePaid`.
 *
 * Requires `STRIPE_SECRET_KEY` in env (the test-mode `rk_test_*` /
 * `sk_test_*` key matching the staging API). Source
 * `.secret/.env.secret` before invoking Playwright.
 */
async function attachDefaultStripeTestCard(
	stripeCustomerId: string,
	stripeSecretKey: string,
	contextLabel: string
): Promise<string> {
	return attachStripeTestCard({
		stripeCustomerId,
		stripeSecretKey,
		contextLabel,
		stripePaymentMethodId: 'pm_card_visa',
		setAsDefault: true
	});
}

type AttachStripeTestCardParams = {
	stripeCustomerId: string;
	stripeSecretKey: string;
	contextLabel: string;
	stripePaymentMethodId: string;
	setAsDefault: boolean;
};

/**
 * TODO: Document attachStripeTestCard.
 */
async function attachStripeTestCard({
	stripeCustomerId,
	stripeSecretKey,
	contextLabel,
	stripePaymentMethodId,
	setAsDefault
}: AttachStripeTestCardParams): Promise<string> {
	const stripeAuthHeaders = {
		Authorization: `Bearer ${stripeSecretKey}`,
		'Content-Type': 'application/x-www-form-urlencoded'
	};

	const attachResp = await fetch(
		`https://api.stripe.com/v1/payment_methods/${encodeURIComponent(stripePaymentMethodId)}/attach`,
		{
			method: 'POST',
			headers: stripeAuthHeaders,
			body: `customer=${encodeURIComponent(stripeCustomerId)}`
		}
	);
	if (!attachResp.ok) {
		throw new Error(
			`${contextLabel} Stripe PaymentMethod.attach failed: ${attachResp.status} ${await attachResp.text()}`
		);
	}
	const paymentMethod = (await attachResp.json()) as { id?: string };
	const defaultPaymentMethodId = requireNonEmptyString(
		paymentMethod.id ?? '',
		`${contextLabel} expected attached PaymentMethod.id from Stripe`
	);

	if (!setAsDefault) {
		return defaultPaymentMethodId;
	}

	const updateResp = await fetch(
		`https://api.stripe.com/v1/customers/${encodeURIComponent(stripeCustomerId)}`,
		{
			method: 'POST',
			headers: stripeAuthHeaders,
			body: `invoice_settings[default_payment_method]=${encodeURIComponent(defaultPaymentMethodId)}`
		}
	);
	if (!updateResp.ok) {
		throw new Error(
			`${contextLabel} Stripe customer default-PM update failed: ${updateResp.status} ${await updateResp.text()}`
		);
	}

	return defaultPaymentMethodId;
}

async function attachNonDefaultStripeTestCard(
	stripeCustomerId: string,
	stripeSecretKey: string,
	contextLabel: string
): Promise<string> {
	return attachStripeTestCard({
		stripeCustomerId,
		stripeSecretKey,
		contextLabel,
		stripePaymentMethodId: 'pm_card_mastercard',
		setAsDefault: false
	});
}

type WaitForStripeDefaultPaymentMethodParams = {
	stripeCustomerId: string;
	stripeSecretKey: string;
	expectedPaymentMethodId: string;
	contextLabel: string;
	maxAttempts?: number;
};

/**
 * TODO: Document waitForStripeDefaultPaymentMethod.
 */
async function waitForStripeDefaultPaymentMethod({
	stripeCustomerId,
	stripeSecretKey,
	expectedPaymentMethodId,
	contextLabel,
	maxAttempts = STRIPE_DEFAULT_PAYMENT_METHOD_WAIT_MAX_ATTEMPTS
}: WaitForStripeDefaultPaymentMethodParams): Promise<string> {
	for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
		const currentDefaultPaymentMethod = await readStripeDefaultPaymentMethod({
			stripeCustomerId,
			stripeSecretKey,
			contextLabel
		});
		if (currentDefaultPaymentMethod === expectedPaymentMethodId) {
			return currentDefaultPaymentMethod;
		}
		await sleep(getTransientRetryDelayMs(attempt));
	}

	throw new Error(
		`${contextLabel} timed out waiting for Stripe default payment method ` +
			`${expectedPaymentMethodId} on customer ${stripeCustomerId}`
	);
}

/**
 * Create a disposable customer fixture that can reach the billing portal.
 */
async function arrangeBillingPortalCustomer({
	trackCustomerForCleanup
}: ArrangeBillingPortalCustomerParams): Promise<ArrangeBillingPortalCustomerResult> {
	try {
		const stripeSecretKey = process.env.STRIPE_SECRET_KEY;
		if (!stripeSecretKey) {
			throw new Error(
				'arrangeBillingPortalCustomer requires STRIPE_SECRET_KEY in env (source .secret/.env.secret before invoking Playwright)'
			);
		}

		const seed = `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
		const email = `billing-portal-${seed}@e2e.griddle.test`;
		const password = 'TestPassword123!';

		const created = await createRegisteredUser({
			apiUrl: fixtureEnv.apiUrl,
			email,
			password,
			name: `Billing Portal ${seed}`,
			trackCustomerForCleanup
		});
		const verificationToken = await resolveFreshSignupVerificationTokenOrAutoVerifiedSentinel(
			email,
			password
		);
		if (!verificationToken.startsWith(LOCAL_AUTO_VERIFIED_TOKEN_PREFIX)) {
			for (let attempt = 0; attempt < TRANSIENT_API_MAX_RETRIES; attempt += 1) {
				const verifyResponse = await callJsonApi(
					fetch,
					fixtureEnv.apiUrl,
					'POST',
					'/auth/verify-email',
					{},
					{ token: verificationToken }
				);
				if (verifyResponse.status === 429) {
					await sleep(getRetryDelayMs(attempt, verifyResponse.headers.get('retry-after')));
					continue;
				}
				if (!verifyResponse.ok) {
					throw new Error(
						`arrangeBillingPortalCustomer verify-email failed: ${verifyResponse.status} ${await verifyResponse.text()}`
					);
				}
				break;
			}
		}
		const token = await loginAsUser({
			apiUrl: fixtureEnv.apiUrl,
			email,
			password
		});

		const currentPlan = await getCurrentBillingPlan(token);
		if (currentPlan !== 'shared') {
			await updateBillingPlan('shared', created.customerId);
		}

		const stripeCustomerId = await syncStripeCustomer(
			created.customerId,
			'arrangeBillingPortalCustomer'
		);

		if (stripeCustomerId.startsWith('cus_local_')) {
			return {
				...created,
				token,
				stripeCustomerId,
				defaultPaymentMethodId: 'pm_local_default',
				nonDefaultPaymentMethodId: 'pm_local_secondary',
				expectedDefaultPaymentMethodId: 'pm_local_secondary'
			};
		}

		const defaultPaymentMethodId = await attachDefaultStripeTestCard(
			stripeCustomerId,
			stripeSecretKey,
			'arrangeBillingPortalCustomer'
		);
		const nonDefaultPaymentMethodId = await attachNonDefaultStripeTestCard(
			stripeCustomerId,
			stripeSecretKey,
			'arrangeBillingPortalCustomer'
		);
		await waitForStripeDefaultPaymentMethod({
			stripeCustomerId,
			stripeSecretKey,
			expectedPaymentMethodId: defaultPaymentMethodId,
			contextLabel: 'arrangeBillingPortalCustomer'
		});

		return {
			...created,
			token,
			stripeCustomerId,
			defaultPaymentMethodId,
			nonDefaultPaymentMethodId,
			expectedDefaultPaymentMethodId: nonDefaultPaymentMethodId
		};
	} catch (error) {
		throwBillingPortalArrangeFailure({
			currentPath: '(arrangeBillingPortalCustomer)',
			error
		});
	}
}

/**
 * TODO: Document resolveInvoiceIdFromBatch.
 */
async function resolveInvoiceIdFromBatch(
	batch: BatchBillingResponse,
	customerId: string,
	token: string,
	billingMonth: string,
	stripeSecretKey: string
): Promise<string> {
	const customerResult = batch.results.find((result) => result.customer_id === customerId);
	if (!customerResult) {
		throw new Error(
			`arrangePaidInvoiceForFreshSignup missing batch result for customer ${customerId}`
		);
	}

	if (customerResult.status === 'created' && customerResult.invoice_id) {
		return customerResult.invoice_id;
	}

	if (customerResult.status === 'skipped' && customerResult.reason === 'already_invoiced') {
		return recoverAlreadyInvoicedInvoiceForMonth({
			billingMonth,
			contextLabel: 'arrangePaidInvoiceForFreshSignup',
			listInvoices: () => listInvoicesBestEffort(token),
			getInvoiceDetail: (invoiceId: string) => getInvoiceDetailForToken(invoiceId, token),
			finalizeDraftInvoice: finalizeExistingInvoiceForFreshSignup,
			payStripeInvoice: (stripeInvoiceId: string) =>
				payStripeInvoiceWithTestKey(
					stripeInvoiceId,
					stripeSecretKey,
					'arrangePaidInvoiceForFreshSignup'
				)
		});
	}

	throw new Error(
		`arrangePaidInvoiceForFreshSignup unexpected batch status for customer ${customerId}: ${customerResult.status} (${customerResult.reason ?? 'no reason'})`
	);
}

type RecoverAlreadyInvoicedInvoiceForMonthParams = {
	billingMonth: string;
	contextLabel: string;
	listInvoices: () => Promise<InvoiceListApiItem[]>;
	getInvoiceDetail: (invoiceId: string) => Promise<InvoiceDetailApiItem | null>;
	finalizeDraftInvoice: (invoiceId: string) => Promise<void>;
	payStripeInvoice: (stripeInvoiceId: string) => Promise<void>;
};

type EnsureInvoicePaymentAttemptForBillingProofParams = {
	invoiceId: string;
	contextLabel: string;
	getInvoiceDetail: (invoiceId: string) => Promise<InvoiceDetailApiItem | null>;
	payStripeInvoice: (stripeInvoiceId: string) => Promise<void>;
};

/**
 * Recover an existing monthly invoice when batch billing reports already_invoiced.
 */
export async function recoverAlreadyInvoicedInvoiceForMonth({
	billingMonth,
	contextLabel,
	listInvoices,
	getInvoiceDetail,
	finalizeDraftInvoice,
	payStripeInvoice
}: RecoverAlreadyInvoicedInvoiceForMonthParams): Promise<string> {
	const monthStart = `${billingMonth}-01`;
	const invoices = await listInvoices();
	const existing = invoices.find((invoice) => invoice.period_start === monthStart);
	if (!existing) {
		throw new Error(
			`${contextLabel} reported already_invoiced for ${billingMonth} but no matching invoice was visible`
		);
	}

	const detail = await getInvoiceDetail(existing.id);
	if (!detail) {
		throw new Error(
			`${contextLabel} could not read existing already_invoiced invoice detail for ${existing.id}`
		);
	}

	if (detail.status === 'draft') {
		await finalizeDraftInvoice(detail.id);
		return detail.id;
	}

	if (
		(detail.status === 'finalized' || detail.status === 'failed') &&
		detail.stripe_invoice_id?.trim()
	) {
		await payStripeInvoice(detail.stripe_invoice_id);
		return detail.id;
	}

	return detail.id;
}

/**
 * Ensure finalized/failed Stripe-backed invoices get an explicit pay attempt
 * before waiting for paid status convergence in remote staging proofs.
 */
export async function ensureInvoicePaymentAttemptForBillingProof({
	invoiceId,
	contextLabel,
	getInvoiceDetail,
	payStripeInvoice
}: EnsureInvoicePaymentAttemptForBillingProofParams): Promise<void> {
	const detail = await getInvoiceDetail(invoiceId);
	if (!detail) {
		throw new Error(`${contextLabel} could not read invoice detail for ${invoiceId}`);
	}

	if (
		(detail.status === 'open' || detail.status === 'finalized' || detail.status === 'failed') &&
		detail.stripe_invoice_id?.trim()
	) {
		await payStripeInvoice(detail.stripe_invoice_id);
	}
}

async function finalizeExistingInvoiceForFreshSignup(invoiceId: string): Promise<void> {
	const finalizeResponse = await adminApiCall(
		'POST',
		`/admin/invoices/${encodeURIComponent(invoiceId)}/finalize`
	);
	if (!finalizeResponse.ok) {
		throw new Error(
			`arrangePaidInvoiceForFreshSignup failed to finalize existing invoice ${invoiceId}: ${finalizeResponse.status} ${await finalizeResponse.text()}`
		);
	}
}

/**
 * TODO: Document payStripeInvoiceWithTestKey.
 */
async function payStripeInvoiceWithTestKey(
	stripeInvoiceId: string,
	stripeSecretKey: string,
	contextLabel: string
): Promise<void> {
	// Local-stack proofs can emit synthetic invoice ids that look Stripe-like
	// (`in_local_*`) but do not exist on stripe.com. Skip remote pay attempts.
	if (stripeInvoiceId.startsWith('in_local_')) {
		return;
	}

	const paymentResponse = await fetch(
		`https://api.stripe.com/v1/invoices/${encodeURIComponent(stripeInvoiceId)}/pay`,
		{
			method: 'POST',
			headers: {
				Authorization: `Bearer ${stripeSecretKey}`,
				'Content-Type': 'application/x-www-form-urlencoded'
			}
		}
	);
	if (!paymentResponse.ok) {
		const responseBody = await paymentResponse.text();
		if (
			paymentResponse.status === 400 &&
			responseBody.toLowerCase().includes('invoice is already paid')
		) {
			// Stripe can return a 400 when an automatic payment has already
			// settled the invoice between our polling intervals. Treat that
			// idempotent state as converged success for the staging proof.
			return;
		}
		throw new Error(
			`${contextLabel} Stripe invoice pay failed for ${stripeInvoiceId}: ${paymentResponse.status} ${responseBody}`
		);
	}
}

/**
 * TODO: Document waitForInvoicePaid.
 */
async function waitForInvoicePaid(invoiceId: string, token: string): Promise<InvoiceDetailApiItem> {
	return waitForInvoiceStatus({
		invoiceId,
		token,
		expectedStatus: 'paid',
		contextLabel: 'arrangePaidInvoiceForFreshSignup'
	});
}

type WaitForInvoiceStatusParams = {
	invoiceId: string;
	token: string;
	expectedStatus: 'paid' | 'refunded';
	contextLabel: string;
};

type WaitForInvoiceStatusForTokenParams = {
	apiUrl: string;
	token: string;
	invoiceId: string;
	expectedStatus: 'paid' | 'refunded';
	contextLabel: string;
	fetchImpl?: typeof fetch;
	maxAttempts?: number;
};

/**
 * TODO: Document waitForInvoiceStatusForToken.
 */
export async function waitForInvoiceStatusForToken({
	apiUrl,
	token,
	invoiceId,
	expectedStatus,
	contextLabel,
	fetchImpl = fetch,
	maxAttempts = INVOICE_STATUS_WAIT_MAX_ATTEMPTS
}: WaitForInvoiceStatusForTokenParams): Promise<InvoiceDetailApiItem> {
	let openWithoutStripeInvoiceIdAttempts = 0;
	let openWithStripeInvoiceIdAttempts = 0;
	for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
		const response = await callJsonApi(
			fetchImpl,
			apiUrl,
			'GET',
			`/invoices/${encodeURIComponent(invoiceId)}`,
			{
				Authorization: `Bearer ${token}`
			}
		);
		if (response.ok) {
			const invoice = (await response.json()) as InvoiceDetailApiItem;
			if (invoice.status === expectedStatus && (expectedStatus !== 'paid' || invoice.paid_at)) {
				return invoice;
			}
			if (expectedStatus === 'paid') {
				const stripeInvoiceId = invoice.stripe_invoice_id?.trim() ?? '';
				if (invoice.status === 'open') {
					if (!stripeInvoiceId) {
						openWithoutStripeInvoiceIdAttempts += 1;
						openWithStripeInvoiceIdAttempts = 0;
						if (openWithoutStripeInvoiceIdAttempts >= INVOICE_OPEN_WITHOUT_STRIPE_ID_MAX_ATTEMPTS) {
							throw new Error(
								`${contextLabel} invoice ${invoiceId} remained open without stripe_invoice_id`
							);
						}
					} else {
						openWithStripeInvoiceIdAttempts += 1;
						openWithoutStripeInvoiceIdAttempts = 0;
						if (openWithStripeInvoiceIdAttempts >= INVOICE_OPEN_WITH_STRIPE_ID_MAX_ATTEMPTS) {
							throw new Error(
								`${contextLabel} invoice ${invoiceId} remained open with stripe_invoice_id present`
							);
						}
					}
				} else {
					openWithoutStripeInvoiceIdAttempts = 0;
					openWithStripeInvoiceIdAttempts = 0;
				}
			}
		} else if (
			response.status !== 404 &&
			response.status !== 429 &&
			response.status !== 503 &&
			response.status < 500
		) {
			throw new Error(
				`${contextLabel} failed to read invoice ${invoiceId}: ${response.status} ${await response.text()}`
			);
		}

		await sleep(getRetryDelayMs(attempt, response.headers.get('retry-after')));
	}

	throw new Error(
		`${contextLabel} timed out waiting for invoice ${invoiceId} to become ${expectedStatus}`
	);
}

/**
 * TODO: Document waitForInvoiceStatus.
 */
async function waitForInvoiceStatus({
	invoiceId,
	token,
	expectedStatus,
	contextLabel
}: WaitForInvoiceStatusParams): Promise<InvoiceDetailApiItem> {
	return waitForInvoiceStatusForToken({
		apiUrl: fixtureEnv.apiUrl,
		token,
		invoiceId,
		expectedStatus,
		contextLabel
	});
}

/**
 * TODO: Document arrangePaidInvoiceForFreshSignup.
 */
async function arrangePaidInvoiceForFreshSignup({
	email,
	password,
	trackCustomerForCleanup
}: ArrangePaidInvoiceForFreshSignupParams): Promise<ArrangePaidInvoiceForFreshSignupResult> {
	try {
		const stripeSecretKey = process.env.STRIPE_SECRET_KEY;
		if (!stripeSecretKey) {
			// Mirror arrangeBillingPortalCustomer's contract: the test-mode
			// Stripe key is what lets us attach pm_card_visa as the default PM
			// so the batch-billing-created invoice can be auto-charged. Without
			// it, the invoice sits in `open` state forever and the spec times
			// out at waitForInvoicePaid.
			throw new Error(
				'arrangePaidInvoiceForFreshSignup requires STRIPE_SECRET_KEY in env (source .secret/.env.secret before invoking Playwright)'
			);
		}

		const normalizedEmail = requireNonEmptyString(
			email,
			'arrangePaidInvoiceForFreshSignup requires a non-empty email and password'
		);
		if (!password.trim()) {
			throw new Error('arrangePaidInvoiceForFreshSignup requires a non-empty email and password');
		}

		const token = await loginAsUserWithKnownMissingUserBootstrap({
			apiUrl: fixtureEnv.apiUrl,
			email: normalizedEmail,
			password,
			trackCustomerForCleanup,
			contextLabel: 'arrangePaidInvoiceForFreshSignup'
		});
		const customerId = await getCustomerIdForToken(token);
		trackCustomerForCleanup(customerId);

		const currentPlan = await getCurrentBillingPlan(token);
		if (currentPlan !== 'shared') {
			await updateBillingPlan('shared', customerId);
		}

		const stripeCustomerId = await syncStripeCustomer(
			customerId,
			'arrangePaidInvoiceForFreshSignup'
		);
		if (stripeCustomerId.startsWith('cus_local_')) {
			throw new Error(
				'arrangePaidInvoiceForFreshSignup local Stripe mode does not support paid-invoice proof fixtures'
			);
		}

		// Local-only Stripe placeholder IDs (`cus_local_*`) are not valid at
		// stripe.com and must skip external card attachment in local-stack proofs.
		if (!stripeCustomerId.startsWith('cus_local_')) {
			// Attach pm_card_visa as the default PM BEFORE batch billing runs,
			// so the invoice that batch billing creates gets auto-charged
			// (collection_method=charge_automatically with a default PM = paid in
			// seconds). Without this step, waitForInvoicePaid below times out.
			const defaultPaymentMethodId = await attachDefaultStripeTestCard(
				stripeCustomerId,
				stripeSecretKey,
				'arrangePaidInvoiceForFreshSignup'
			);
			// Stripe can acknowledge attachment before `invoice_settings.default_payment_method`
			// is query-consistent. Wait for that read seam to converge before batch billing.
			await waitForStripeDefaultPaymentMethod({
				stripeCustomerId,
				stripeSecretKey,
				expectedPaymentMethodId: defaultPaymentMethodId,
				contextLabel: 'arrangePaidInvoiceForFreshSignup'
			});
		}

		const billingMonth = currentUtcBillingMonth();
		const batchBillingResponse = await adminApiCall('POST', '/admin/billing/run', {
			month: billingMonth
		});
		if (!batchBillingResponse.ok) {
			throw new Error(
				`arrangePaidInvoiceForFreshSignup failed to run batch billing: ${batchBillingResponse.status} ${await batchBillingResponse.text()}`
			);
		}

		const batch = (await batchBillingResponse.json()) as BatchBillingResponse;
		const invoiceId = await resolveInvoiceIdFromBatch(
			batch,
			customerId,
			token,
			billingMonth,
			stripeSecretKey
		);
		await ensureInvoicePaymentAttemptForBillingProof({
			invoiceId,
			contextLabel: 'arrangePaidInvoiceForFreshSignup',
			getInvoiceDetail: (id) => getInvoiceDetailForToken(id, token),
			payStripeInvoice: (stripeInvoiceId) =>
				payStripeInvoiceWithTestKey(
					stripeInvoiceId,
					stripeSecretKey,
					'arrangePaidInvoiceForFreshSignup'
				)
		});
		await waitForInvoicePaid(invoiceId, token);
		const paidInvoiceEvidence =
			process.env[REMOTE_TARGET_OPT_IN_ENV] === '1'
				? await findPaidInvoiceEvidenceViaStagingSsm(normalizedEmail, invoiceId)
				: {
						stagingCustomerId: customerId,
						stagingInvoiceId: invoiceId,
						stagingInvoiceStatus: 'paid',
						stagingInvoicePeriodStart: `${billingMonth}-01`
					};

		return {
			customerId,
			invoiceId,
			billingMonth,
			stagingCustomerId: paidInvoiceEvidence.stagingCustomerId,
			stagingInvoiceId: paidInvoiceEvidence.stagingInvoiceId,
			stagingInvoiceStatus: paidInvoiceEvidence.stagingInvoiceStatus,
			stagingInvoicePeriodStart: paidInvoiceEvidence.stagingInvoicePeriodStart
		};
	} catch (error) {
		const diagnosticEnv = fixtureEnvForFailureDiagnostics();
		throw new Error(
			formatFixtureSetupFailure({
				setupName: 'arrangePaidInvoiceForFreshSignup',
				expectedPath: '/console/billing/invoices/{id}',
				currentPath: '(arrangePaidInvoiceForFreshSignup)',
				apiUrl: diagnosticEnv.apiUrl,
				adminKey: diagnosticEnv.adminKey,
				alertText: setupFailureDetailsFromError(error)
			})
		);
	}
}

type InvoiceListApiItem = {
	id: string;
	status: string;
	period_start: string;
};

type InvoiceDetailApiItem = {
	id: string;
	status: string;
	paid_at: string | null;
	pdf_url: string | null;
	stripe_invoice_id?: string | null;
};

async function listInvoicesBestEffort(tokenOverride?: string): Promise<InvoiceListApiItem[]> {
	const res = await apiCall('GET', '/invoices', undefined, tokenOverride);
	if (!res.ok) {
		return [];
	}
	return (await res.json()) as InvoiceListApiItem[];
}

async function createDraftInvoice(month = '2025-01'): Promise<{ id: string }> {
	const customerId = await getCustomerId();
	const res = await adminApiCall(
		'POST',
		`/admin/tenants/${encodeURIComponent(customerId)}/invoices`,
		{
			month
		}
	);
	if (!res.ok) {
		throw new Error(`seedInvoice failed: ${res.status} ${await res.text()}`);
	}
	return (await res.json()) as { id: string };
}

async function getInvoiceDetailForFixture(invoiceId: string): Promise<InvoiceDetailApiItem | null> {
	const res = await apiCall('GET', `/invoices/${encodeURIComponent(invoiceId)}`);
	if (!res.ok) {
		return null;
	}
	return (await res.json()) as InvoiceDetailApiItem;
}

/**
 * TODO: Document getInvoiceDetailForToken.
 */
async function getInvoiceDetailForToken(
	invoiceId: string,
	token: string
): Promise<InvoiceDetailApiItem | null> {
	const res = await callJsonApi(
		fetch,
		fixtureEnv.apiUrl,
		'GET',
		`/invoices/${encodeURIComponent(invoiceId)}`,
		{ Authorization: `Bearer ${token}` }
	);
	if (!res.ok) {
		return null;
	}
	return (await res.json()) as InvoiceDetailApiItem;
}

// ---------------------------------------------------------------------------
// Custom fixture types
// ---------------------------------------------------------------------------

type SeedIndexFn = (name: string, region?: string, options?: SeedIndexOptions) => Promise<void>;
type SeedRecommendationsConfigResult = {
	indexName: string;
	primaryObjectID: string;
	secondaryObjectID: string;
	facetName: string;
	facetValue: string;
	missingFacetValue: string;
};
type SeedRecommendationsConfigFn = (
	name: string,
	region?: string
) => Promise<SeedRecommendationsConfigResult>;
type SeedCustomerIndexFn = (
	customer: CreatedFixtureUser,
	name: string,
	region?: string,
	flapjackUrl?: string,
	options?: SeedIndexOptions
) => Promise<void>;
type RegisterIndexForCleanupFn = (name: string, options?: RegisterIndexCleanupOptions) => void;
type CleanupFixtureIndexesFn = () => Promise<void>;
type SeedApiKeyFn = (name: string, scopes?: string[]) => Promise<{ id: string }>;
type SeedRulePayload = { objectID: string } & Record<string, unknown>;
type SeedRulesFn = (indexName: string, rules: SeedRulePayload[]) => Promise<void>;
type SeedPersonalizationStrategyFn = (
	indexName: string,
	strategy: Record<string, unknown>
) => Promise<void>;
type GetRuleFn = (indexName: string, objectID: string) => Promise<Rule>;
type SearchRulesFn = (
	indexName: string,
	query?: string,
	page?: number,
	hitsPerPage?: number
) => Promise<RuleSearchResponse>;
type ReadClipboardTextFn = (page: Page) => Promise<string>;
type SeedSynonymFn = (indexName: string, synonym: Synonym) => Promise<void>;
type GetSynonymFn = (indexName: string, objectID: string) => Promise<Synonym | null>;
type SearchSynonymsFn = (indexName: string, query?: string) => Promise<SynonymSearchResponse>;
type ClearSynonymsFn = (indexName: string) => Promise<void>;
type AssertIndexNeverReadableFn = (indexName: string) => Promise<void>;
type WriteSynonymsProofManifestFn = (input: WriteSynonymsProofManifestInput) => Promise<void>;
type ListApiKeysFn = () => Promise<ApiKeyListItem[]>;
type DiscoverWithApiKeyFn = (
	indexName: string,
	apiKey: string
) => Promise<{
	status: number;
	body: {
		vm?: string;
		flapjack_url?: string;
		ttl?: number;
		service_type?: string;
	} | null;
}>;
type SetBillingPlanFn = (plan: 'free' | 'shared') => Promise<void>;
type SetBillingPlanForCustomerFn = (customerId: string, plan: 'free' | 'shared') => Promise<void>;
type GetAccountPayloadForTokenFn = (
	token: string
) => Promise<{ id?: string; billing_plan?: 'free' | 'shared' }>;
type SeedEventPayload = {
	eventType: 'view' | 'click' | 'conversion';
	eventSubtype?: string;
	eventName: string;
	userToken: string;
	objectIDs: string[];
	timestampMs?: number;
};
type SeedEventsFn = (indexName: string, events: SeedEventPayload[]) => Promise<void>;
type GetDebugEventsFn = (
	indexName: string,
	query?: { eventType?: string; status?: string; limit?: number; from?: number; until?: number }
) => Promise<{ events: DebugEvent[]; count: number }>;
type SeedInvoiceFn = () => Promise<{ id: string }>;
type SeedInvoiceWithPdfUrlFn = () => Promise<{ id: string }>;
type CreateUserFn = (email: string, password: string, name?: string) => Promise<CreatedFixtureUser>;
export type LoginAsFn = (email: string, password: string) => Promise<string>;
type ArrangeTrackedCustomerSessionOptions = {
	emailPrefix: string;
	password?: string;
	name?: string;
	verifyEmail?: boolean;
};
type ArrangeTrackedCustomerSessionFn = (
	page: Page,
	options: ArrangeTrackedCustomerSessionOptions
) => Promise<CreatedFixtureUser>;
type WaitForStripeDefaultPaymentMethodFn = (
	stripeCustomerId: string,
	expectedPaymentMethodId: string
) => Promise<string>;
type GetEstimatedBillFn = (month?: string) => Promise<EstimatedBillResponse | null>;
type SeedMultiUserScenarioFn = () => Promise<{
	primaryUser: CreatedFixtureUser;
	secondaryUser: CreatedFixtureUser;
}>;
type AdminReactivateCustomerFn = (customerId: string) => Promise<void>;
type AdminSuspendCustomerFn = (customerId: string) => Promise<void>;
type SeedAdminDeploymentFn = (
	customer: CreatedFixtureUser,
	options?: { region?: string }
) => Promise<AdminDeploymentFixture>;
type GetDisposableTenantRateCardSnapshotFn = () => Promise<MarketingPricingContractSnapshot>;
type ArrangeBillingPortalCustomerFn = () => Promise<ArrangeBillingPortalCustomerResult>;
type CreateFreshSignupIdentityFn = () => FreshSignupIdentity;
type FindCustomerStatusViaStagingSsmFn = (email: string) => Promise<StagingCustomerStatusEvidence>;
type FindPaidInvoiceEvidenceViaStagingSsmFn = (
	invoiceId: string
) => Promise<StagingPaidInvoiceEvidence>;
type CompleteFreshSignupEmailVerificationFn = (
	page: Page,
	email: string,
	password?: string
) => Promise<{ verificationToken: string }>;
type EnsureLocalSharedVmInventoryFn = (region: string) => Promise<void>;
type ArrangePaidInvoiceForFreshSignupFn = (
	email: string,
	password: string
) => Promise<ArrangePaidInvoiceForFreshSignupResult>;
type ArrangeFreshSignupToDashboardFn = (
	page: Page,
	signup: FreshSignupIdentity
) => Promise<ArrangeFreshSignupToDashboardResult>;
type IsFreshSignupArrangePrerequisiteFailureFn = (alertText: string) => boolean;
type ThrowFreshSignupArrangeFailureFn = (input: {
	currentPath: string;
	alertText?: string | null;
	responseStatus?: number;
	responseUrl?: string;
}) => never;

/**
 * TODO: Document E2eFixtures.
 */
type E2eFixtures = {
	/** Resolved API origin from resolveFixtureEnv (single env-contract owner). */
	apiUrl: string;
	/** Seed an index via the admin API and auto-delete after the test. */
	seedIndex: SeedIndexFn;
	/** Seed an index for a newly-created customer fixture without switching browser auth state. */
	seedCustomerIndex: SeedCustomerIndexFn;
	/** Register an index name for teardown when the index is created via UI flow. */
	registerIndexForCleanup: RegisterIndexForCleanupFn;
	/** Seed a synonym through fixture-owned bearer-token API access. */
	seedSynonym: SeedSynonymFn;
	/** Read a synonym object through fixture-owned bearer-token API access. */
	getSynonym: GetSynonymFn;
	/** Search synonyms through fixture-owned bearer-token API access. */
	searchSynonyms: SearchSynonymsFn;
	/** Clear all synonyms through fixture-owned bearer-token API access. */
	clearSynonyms: ClearSynonymsFn;
	/** Prove an index stays unreadable across the seeded-index readiness window. */
	assertIndexNeverReadable: AssertIndexNeverReadableFn;
	/** Emit shell-readable Stage 5 synonyms proof metadata and cleanup contract. */
	writeSynonymsProofManifest: WriteSynonymsProofManifestFn;
	/** Remove leaked safe-to-delete test indexes from prior runs for the shared fixture user. */
	cleanupFixtureIndexes: CleanupFixtureIndexesFn;
	/** Seed an API key and auto-revoke after the test. */
	seedApiKey: SeedApiKeyFn;
	/** Seed one or more rules and auto-delete them after the test. */
	seedRules: SeedRulesFn;
	/** Seed a personalization strategy through fixture-owned bearer-token API access. */
	seedPersonalizationStrategy: SeedPersonalizationStrategyFn;
	/** Seed Insights events via POST to the flapjack engine for debug-event testing. */
	seedEvents: SeedEventsFn;
	/** Read debug events for an index through fixture-owned API access. */
	getDebugEvents: GetDebugEventsFn;
	/** Read a single rule by objectID through fixture-owned API access. */
	getRule: GetRuleFn;
	/** Search rules through fixture-owned API access. */
	searchRules: SearchRulesFn;
	/** Read clipboard text through fixture-owned browser permission seam. */
	readClipboardText: ReadClipboardTextFn;
	/** Read API-key rows for the authenticated customer through fixture-owned API access. */
	listApiKeys: ListApiKeysFn;
	/** Call /discover with a bearer API key through fixture-owned API access. */
	discoverWithApiKey: DiscoverWithApiKeyFn;
	/** Temporarily switch the authenticated customer between free and shared plans. */
	setBillingPlan: SetBillingPlanFn;
	/** Set a specific customer's plan through fixture-owned admin mutation flow. */
	setBillingPlanForCustomer: SetBillingPlanForCustomerFn;
	/** Read /account payload for a specific auth token through fixture-owned retry semantics. */
	getAccountPayloadForToken: GetAccountPayloadForTokenFn;
	/** Seed a recommendation-ready index with deterministic object/facet fixture data. */
	seedRecommendationsConfig: SeedRecommendationsConfigFn;
	/** Seed an index backed by Flapjack with searchable documents. */
	seedSearchableIndex: SeedSearchableIndexFn;
	/** Ensure an invoice exists for the test user and return its ID. */
	seedInvoice: SeedInvoiceFn;
	/** Ensure a finalized invoice with `pdf_url` exists and return its ID. */
	seedInvoiceWithPdfUrl: SeedInvoiceWithPdfUrlFn;
	/** Create a login-capable user through POST /auth/register for cross-user scenarios. */
	createUser: CreateUserFn;
	/** Login as an explicit user and return a fresh token. */
	loginAs: LoginAsFn;
	/** Create a tracked disposable customer and authenticate the browser as that customer. */
	arrangeTrackedCustomerSession: ArrangeTrackedCustomerSessionFn;
	/** Poll Stripe customer state until the expected default payment method is active. */
	waitForStripeDefaultPaymentMethod: WaitForStripeDefaultPaymentMethodFn;
	/** Fetch the authenticated customer's current estimated bill. */
	getEstimatedBill: GetEstimatedBillFn;
	/** Seed two unique users for multi-user workflows. */
	seedMultiUserScenario: SeedMultiUserScenarioFn;
	/** Reactivate a suspended customer through the existing admin route. */
	adminReactivateCustomer: AdminReactivateCustomerFn;
	/** Suspend an active customer through the existing admin route. */
	adminSuspendCustomer: AdminSuspendCustomerFn;
	/** Seed a real admin-visible deployment row for a disposable customer. */
	seedAdminDeployment: SeedAdminDeploymentFn;
	/** Create a disposable tenant and return a normalized snapshot of /admin/tenants/{id}/rate-card. */
	getDisposableTenantRateCardSnapshot: GetDisposableTenantRateCardSnapshotFn;
	/** Provision a disposable customer fixture that can access Stripe portal with subscription state arranged. */
	arrangeBillingPortalCustomer: ArrangeBillingPortalCustomerFn;
	/** Create unique, deterministic signup credentials for fresh-user browser flows. */
	createFreshSignupIdentity: CreateFreshSignupIdentityFn;
	/** Read customer status evidence from staging DB through the shared lookup seam. */
	findCustomerStatusViaStagingSsm: FindCustomerStatusViaStagingSsmFn;
	/** Read paid-invoice evidence for the fixture user from staging DB through the shared lookup seam. */
	findPaidInvoiceEvidenceViaStagingSsm: FindPaidInvoiceEvidenceViaStagingSsmFn;
	/** Resolve a real Mailpit token and complete /verify-email/{token} in the browser. */
	completeFreshSignupEmailVerification: CompleteFreshSignupEmailVerificationFn;
	/** Keep local browser create-index placement pointed at the current Flapjack process. */
	ensureLocalSharedVmInventory: EnsureLocalSharedVmInventoryFn;
	/** Advance a fresh verified signup through paid billing and invoice-email evidence. */
	arrangePaidInvoiceForFreshSignup: ArrangePaidInvoiceForFreshSignupFn;
	/** Create a fresh signup through UI and land on /console with remote-target fallback. */
	arrangeFreshSignupToDashboard: ArrangeFreshSignupToDashboardFn;
	/** Detects known prerequisite/setup failures surfaced from fresh-signup UI alerts. */
	isFreshSignupArrangePrerequisiteFailure: IsFreshSignupArrangePrerequisiteFailureFn;
	/** Throws a fixture-owned fail-closed setup error for fresh-signup prerequisites. */
	throwFreshSignupArrangeFailure: ThrowFreshSignupArrangeFailureFn;
	/** Default region for index creation (via resolveFixtureEnv). */
	testRegion: string;
};

type E2eInternalFixtures = {
	/** Internal registry used by fixtures to clean up test-created indexes. */
	_trackIndexForCleanup: RegisterIndexForCleanupFn;
	/** Internal registry used by fixtures to clean up test-created customers. */
	_trackCustomerForCleanup: TrackCustomerForCleanupFn;
};

// ---------------------------------------------------------------------------
// Extended test object
// ---------------------------------------------------------------------------

export const test = base.extend<E2eFixtures & E2eInternalFixtures>({
	// Override the built-in page fixture so that every page.goto() call waits
	// for the network to be idle before returning.  In Vite dev mode the client
	// JS is served as individual ES modules loaded via async import().  The
	// default waitUntil:'load' resolves as soon as the initial HTML document and
	// synchronous resources are ready — well before Svelte components hydrate
	// and register their onclick handlers.  Without networkidle the test can
	// click a button before the event listener is attached and the interaction
	// is silently dropped.
	page: async ({ page }, use) => {
		const originalGoto = page.goto.bind(page);
		// eslint-disable-next-line @typescript-eslint/no-explicit-any
		(page as any).goto = async (
			...args: Parameters<typeof originalGoto>
		): ReturnType<typeof originalGoto> => {
			const response = await originalGoto(...args);
			// Remote staging pages can keep long-lived requests open, so waiting
			// for networkidle can deadlock navigation in LB-2/LB-3 proofs.
			if (isRemoteTargetMode()) {
				return response;
			}
			await page.waitForLoadState('networkidle');
			return response;
		};

		// Auto-accept browser confirm/alert dialogs so that tests exercising
		// buttons that use window.confirm() for confirmation behave like a user
		// clicking OK.  Without this, headless Chromium dismisses the dialog
		// with false, which triggers e.preventDefault() and blocks the action.
		page.on('dialog', (dialog) => dialog.accept());

		await use(page);
	},

	testRegion: async ({}, use) => {
		await use(fixtureEnv.testRegion);
	},

	apiUrl: async ({}, use) => {
		await use(fixtureEnv.apiUrl);
	},

	_trackIndexForCleanup: async ({}, use) => {
		await runTrackedIndexCleanup(async (trackIndexForCleanup) => {
			await use(trackIndexForCleanup);
		});
	},

	_trackCustomerForCleanup: async ({}, use) => {
		await runTrackedCustomerCleanup(async (trackCustomerForCleanup) => {
			await use(trackCustomerForCleanup);
		});
	},

	createUser: async ({ _trackCustomerForCleanup }, use) => {
		await use((email, password, name) =>
			createRegisteredUser({
				apiUrl: fixtureEnv.apiUrl,
				email,
				password,
				name,
				trackCustomerForCleanup: _trackCustomerForCleanup
			})
		);
	},

	getDisposableTenantRateCardSnapshot: async ({ _trackCustomerForCleanup }, use) => {
		await use(async () => {
			return fetchDisposableTenantRateCardSnapshot({
				apiUrl: fixtureEnv.apiUrl,
				adminKey: fixtureEnv.adminKey,
				trackCustomerForCleanup: _trackCustomerForCleanup
			});
		});
	},

	arrangeBillingPortalCustomer: async ({ _trackCustomerForCleanup }, use) => {
		await use(() =>
			arrangeBillingPortalCustomer({
				trackCustomerForCleanup: _trackCustomerForCleanup
			})
		);
	},

	createFreshSignupIdentity: async ({}, use) => {
		await use(() => buildFreshSignupIdentity());
	},

	findCustomerStatusViaStagingSsm: async ({}, use) => {
		await use((email) => findCustomerStatusViaStagingSsm(email));
	},

	findPaidInvoiceEvidenceViaStagingSsm: async ({}, use) => {
		await use((invoiceId: string) =>
			findPaidInvoiceEvidenceViaStagingSsm(
				requireNonEmptyString(
					fixtureEnv.userEmail ?? '',
					'findPaidInvoiceEvidenceViaStagingSsm requires fixture user email'
				),
				invoiceId
			)
		);
	},

	completeFreshSignupEmailVerification: async ({}, use) => {
		await use((page, email, password) =>
			completeFreshSignupEmailVerificationViaRoute(page, email, password)
		);
	},

	ensureLocalSharedVmInventory: async ({}, use) => {
		await use((region: string) => ensureLocalSharedVmInventoryForRegion(region));
	},

	arrangePaidInvoiceForFreshSignup: async ({ _trackCustomerForCleanup }, use) => {
		await use((email, password) =>
			arrangePaidInvoiceForFreshSignup({
				email,
				password,
				trackCustomerForCleanup: _trackCustomerForCleanup
			})
		);
	},

	arrangeFreshSignupToDashboard: async ({ createUser, _trackCustomerForCleanup }, use) => {
		await use((page, signup) =>
			arrangeFreshSignupToDashboardWithFixtureFallback({
				page,
				signup,
				createUser,
				trackCustomerForCleanup: _trackCustomerForCleanup
			})
		);
	},

	isFreshSignupArrangePrerequisiteFailure: async ({}, use) => {
		await use((alertText) => isFreshSignupArrangePrerequisiteFailure(alertText));
	},

	throwFreshSignupArrangeFailure: async ({}, use) => {
		await use((input) => throwFreshSignupArrangeFailure(input));
	},

	loginAs: async ({}, use) => {
		await use((email, password) =>
			loginAsUser({
				apiUrl: fixtureEnv.apiUrl,
				email,
				password
			})
		);
	},

	arrangeTrackedCustomerSession: async ({ createUser, loginAs }, use) => {
		const previousToken = _token;
		const previousCustomerId = _customerId;
		await use(async (page, options) => {
			const customer = await arrangeTrackedCustomerSessionForPage({
				page,
				options,
				createUser,
				loginAs
			});
			_token = customer.token;
			_customerId = customer.customerId;
			return customer;
		});
		_token = previousToken;
		_customerId = previousCustomerId;
	},

	waitForStripeDefaultPaymentMethod: async ({}, use) => {
		await use(async (stripeCustomerId, expectedPaymentMethodId) => {
			const stripeSecretKey = process.env.STRIPE_SECRET_KEY;
			if (!stripeSecretKey) {
				throw new Error(
					'waitForStripeDefaultPaymentMethod requires STRIPE_SECRET_KEY in env (source .secret/.env.secret before invoking Playwright)'
				);
			}

			return waitForStripeDefaultPaymentMethod({
				stripeCustomerId,
				stripeSecretKey,
				expectedPaymentMethodId,
				contextLabel: 'waitForStripeDefaultPaymentMethod'
			});
		});
	},

	getEstimatedBill: async ({}, use) => {
		await use(async (month) => {
			const token = await getAuthToken();
			return fetchEstimatedBillForToken({
				apiUrl: fixtureEnv.apiUrl,
				token,
				month
			});
		});
	},

	seedMultiUserScenario: async ({ createUser }, use) => {
		await use(() => seedMultiUserScenarioWithCreateUser({ createUser }));
	},

	adminReactivateCustomer: async ({}, use) => {
		await use((customerId) =>
			adminReactivateCustomerById({
				apiUrl: fixtureEnv.apiUrl,
				customerId,
				adminKey: fixtureEnv.adminKey
			})
		);
	},

	adminSuspendCustomer: async ({}, use) => {
		await use((customerId) =>
			adminSuspendCustomerById({
				apiUrl: fixtureEnv.apiUrl,
				customerId,
				adminKey: fixtureEnv.adminKey
			})
		);
	},

	seedAdminDeployment: async ({}, use) => {
		await use((customer, options) => seedAdminDeploymentForCustomer(customer, options));
	},

	registerIndexForCleanup: async ({ _trackIndexForCleanup }, use) => {
		await use((name: string, options?: RegisterIndexCleanupOptions) =>
			_trackIndexForCleanup(name, options)
		);
	},

	seedSynonym: async ({}, use) => {
		await use((indexName: string, synonym: Synonym) =>
			saveSynonymWithFixtureApi(indexName, synonym)
		);
	},

	getSynonym: async ({}, use) => {
		await use((indexName: string, objectID: string) =>
			getSynonymWithFixtureApi(indexName, objectID)
		);
	},

	searchSynonyms: async ({}, use) => {
		await use((indexName: string, query = '') => searchSynonymsWithFixtureApi(indexName, query));
	},

	clearSynonyms: async ({}, use) => {
		await use((indexName: string) => clearSynonymsWithFixtureApi(indexName));
	},

	assertIndexNeverReadable: async ({}, use) => {
		await use((indexName: string) => assertIndexNeverBecomesReadable(indexName));
	},

	writeSynonymsProofManifest: async ({}, use) => {
		await use((input: WriteSynonymsProofManifestInput) => writeSynonymsProofManifest(input));
	},

	cleanupFixtureIndexes: async ({}, use) => {
		await use(() => cleanupStaleFixtureIndexesOnce({ force: true }));
	},

	seedIndex: async ({ _trackIndexForCleanup }, use) => {
		const factory: SeedIndexFn = async (name, region, options) => {
			await cleanupStaleFixtureIndexesOnce();
			const r = region ?? fixtureEnv.testRegion;
			const deferCleanup = Boolean(options?.deferCleanup);
			if (deferCleanup) {
				// Reject stale-prefix proof names before provisioning so deferred
				// proof failures never leak an index outside the tracked cleanup seam.
				assertDeferredProofIndexAvoidsStalePrefixes(name);
			}
			// Use the admin endpoint to seed a local Flapjack-backed index directly
			// so tab/detail browser proofs exercise the real local engine. When
			// admin auth is invalid mid-suite (shared-host API restart), fall back
			// to the authenticated customer route. Wrap the whole sequence in a
			// short transport-retry loop so a single fetch disconnect (worker
			// restart, port flap) does not fail the spec.
			const customerId = await getCustomerId();
			for (let attempt = 0; attempt < 3; attempt++) {
				try {
					try {
						await createSeededIndex(customerId, name, r, fixtureEnv.flapjackUrl);
					} catch (error) {
						if (
							error instanceof Error &&
							error.message.toLowerCase().includes('invalid admin key')
						) {
							await createSeededIndexForCurrentCustomer(name, r);
						} else {
							throw error;
						}
					}
					// The admin create endpoint can return before the customer
					// index-read path is consistent enough for the detail page
					// loader. Poll the same read path the UI uses so seeded detail
					// specs do not flake on a 500.
					await waitForSeededIndex(name);
					if (options?.settings) {
						await updateSeededIndexSettings(name, options.settings);
					}
					await raiseRemoteSeededIndexWriteQuota(customerId);
					_trackIndexForCleanup(name, { deferCleanup });
					if (deferCleanup) {
						await writeSynonymsProofManifest({
							indexName: name,
							objectIDs: [],
							manifestPath: options?.proofManifestPath
						});
					}
					return;
				} catch (error) {
					if (isTransientSeedIndexTransportFailure(error) && attempt < 2) {
						await sleep(getTransientRetryDelayMs(attempt));
						continue;
					}
					throw error;
				}
			}
		};

		await use(factory);
	},

	seedCustomerIndex: async ({}, use) => {
		const created: TrackedCustomerIndex[] = [];

		const factory: SeedCustomerIndexFn = async (customer, name, region, flapjackUrl, options) => {
			const r = region ?? fixtureEnv.testRegion;
			await seedCustomerIndexForFixture({
				customer,
				name,
				region: r,
				flapjackUrl: flapjackUrl ?? fixtureEnv.flapjackUrl,
				options,
				trackCreatedIndex: (entry) => created.push(entry)
			});
		};

		await use(factory);

		for (const index of created) {
			if (index.deferCleanup) {
				continue;
			}
			await callJsonApi(
				fetch,
				fixtureEnv.apiUrl,
				'DELETE',
				`/indexes/${encodeURIComponent(index.name)}`,
				{ Authorization: `Bearer ${index.token}` },
				{ confirm: true }
			).catch(() => {
				/* ignore — the owning customer cleanup may already have removed access */
			});
		}
	},

	seedApiKey: async ({}, use) => {
		const created: string[] = [];

		const factory: SeedApiKeyFn = async (name, scopes = ['search']) => {
			const res = await apiCall('POST', '/api-keys', { name, scopes });
			if (!res.ok) {
				throw new Error(`seedApiKey failed: ${res.status} ${await res.text()}`);
			}
			const data = (await res.json()) as { id: string };
			created.push(data.id);
			return { id: data.id };
		};

		await use(factory);

		// Teardown: revoke all seeded keys
		for (const id of created) {
			await apiCall('DELETE', `/api-keys/${id}`).catch(() => {
				/* ignore — may already be gone */
			});
		}
	},

	seedRules: async ({}, use) => {
		const createdRules: Array<{ indexName: string; objectID: string }> = [];

		const factory: SeedRulesFn = async (indexName, rules) => {
			for (const rule of rules) {
				const objectID = rule.objectID;
				if (!objectID) {
					throw new Error('seedRules requires each rule to include a non-empty objectID');
				}
				let saved = false;
				let lastFailure = 'none';
				for (let attempt = 0; attempt < TRANSIENT_API_MAX_RETRIES; attempt += 1) {
					const response = await apiCall(
						'PUT',
						`/indexes/${encodeURIComponent(indexName)}/rules/${encodeURIComponent(objectID)}`,
						rule
					);
					if (response.ok) {
						saved = true;
						break;
					}
					const body = await response.text();
					lastFailure = `${response.status} ${body}`;
					if (
						response.status === 404 ||
						response.status === 429 ||
						response.status === 500 ||
						response.status === 503
					) {
						await sleep(getRetryDelayMs(attempt, response.headers.get('retry-after')));
						continue;
					}
					throw new Error(`seedRules failed: ${lastFailure}`);
				}
				if (!saved) {
					throw new Error(`seedRules failed after transient retries: ${lastFailure}`);
				}
				createdRules.push({ indexName, objectID });
			}
		};

		await use(factory);

		for (const createdRule of createdRules) {
			await apiCall(
				'DELETE',
				`/indexes/${encodeURIComponent(createdRule.indexName)}/rules/${encodeURIComponent(createdRule.objectID)}`
			).catch(() => {
				/* ignore — may already be gone */
			});
		}
	},

	seedPersonalizationStrategy: async ({}, use) => {
		const fixture: SeedPersonalizationStrategyFn = async (indexName, strategy) => {
			let lastFailure = 'none';
			for (let attempt = 0; attempt < TRANSIENT_API_MAX_RETRIES; attempt += 1) {
				const response = await apiCall(
					'PUT',
					`/indexes/${encodeURIComponent(indexName)}/personalization/strategy`,
					strategy
				);
				if (response.ok) return;

				const body = await response.text();
				lastFailure = `${response.status} ${body}`;
				if (
					response.status === 404 ||
					response.status === 429 ||
					response.status === 500 ||
					response.status === 503
				) {
					await sleep(getRetryDelayMs(attempt, response.headers.get('retry-after')));
					continue;
				}
				break;
			}
			throw new Error(`seedPersonalizationStrategy failed: ${lastFailure}`);
		};
		await use(fixture);
	},

	seedEvents: async ({}, use) => {
		const factory: SeedEventsFn = async (indexName, events) => {
			const customerId = await getCustomerId();
			const flapjackIndexUid = buildTenantScopedIndexUid(customerId, indexName);
			const safeFlapjackUrl = requireLoopbackHttpUrl('FLAPJACK_URL', fixtureEnv.flapjackUrl);

			const keyRes = await apiCall('POST', `/indexes/${encodeURIComponent(indexName)}/keys`, {
				description: `seedEvents fixture key for ${indexName}`,
				acl: ['search', 'addObject']
			});
			if (!keyRes.ok) {
				throw new Error(`seedEvents: key creation failed: ${keyRes.status} ${await keyRes.text()}`);
			}
			const { key } = (await keyRes.json()) as { key: string };

			const insightsPayload = {
				events: events.map((e) => ({
					eventType: e.eventType,
					eventSubtype: e.eventSubtype ?? undefined,
					eventName: e.eventName,
					index: flapjackIndexUid,
					userToken: e.userToken,
					objectIDs: e.objectIDs,
					timestamp: e.timestampMs ?? Date.now()
				}))
			};

			let lastFailure = 'none';
			for (let attempt = 0; attempt < TRANSIENT_API_MAX_RETRIES; attempt += 1) {
				const res = await fetch(`${safeFlapjackUrl}/1/events`, {
					method: 'POST',
					headers: {
						'Content-Type': 'application/json',
						'X-Algolia-API-Key': key,
						'X-Algolia-Application-Id': 'flapjack'
					},
					body: JSON.stringify(insightsPayload)
				});
				if (res.ok || res.status === 202) break;
				lastFailure = `${res.status} ${await res.text()}`;
				if (res.status === 429 || res.status === 500 || res.status === 503) {
					await sleep(getRetryDelayMs(attempt, res.headers.get('retry-after')));
					continue;
				}
				throw new Error(`seedEvents failed: ${lastFailure}`);
			}
		};
		await use(factory);
	},

	getDebugEvents: async ({}, use) => {
		const fixture: GetDebugEventsFn = async (indexName, query) => {
			const params = new URLSearchParams();
			if (query?.eventType) params.set('eventType', query.eventType);
			if (query?.status) params.set('status', query.status);
			if (query?.limit !== undefined) params.set('limit', String(query.limit));
			if (query?.from !== undefined) params.set('from', String(query.from));
			if (query?.until !== undefined) params.set('until', String(query.until));
			const qs = params.toString();
			const path = `/indexes/${encodeURIComponent(indexName)}/events/debug${qs ? `?${qs}` : ''}`;
			const response = await apiCall('GET', path);
			if (!response.ok) {
				throw new Error(`getDebugEvents failed: ${response.status} ${await response.text()}`);
			}
			return (await response.json()) as { events: DebugEvent[]; count: number };
		};
		await use(fixture);
	},

	getRule: async ({}, use) => {
		const fixture: GetRuleFn = async (indexName, objectID) => {
			const response = await apiCall(
				'GET',
				`/indexes/${encodeURIComponent(indexName)}/rules/${encodeURIComponent(objectID)}`
			);
			if (!response.ok) {
				throw new Error(`getRule failed: ${response.status} ${await response.text()}`);
			}
			return (await response.json()) as Rule;
		};
		await use(fixture);
	},

	searchRules: async ({}, use) => {
		const fixture: SearchRulesFn = async (indexName, query = '', page = 0, hitsPerPage = 50) => {
			const response = await apiCall(
				'POST',
				`/indexes/${encodeURIComponent(indexName)}/rules/search`,
				{
					query,
					page,
					hitsPerPage
				}
			);
			if (!response.ok) {
				throw new Error(`searchRules failed: ${response.status} ${await response.text()}`);
			}
			return (await response.json()) as RuleSearchResponse;
		};
		await use(fixture);
	},

	readClipboardText: async ({}, use) => {
		const fixture: ReadClipboardTextFn = async (page) => {
			try {
				return await page.evaluate(async () => navigator.clipboard.readText());
			} catch (error) {
				throw new Error(
					`readClipboardText failed to access navigator.clipboard.readText(): ${setupFailureDetailsFromError(error)}`
				);
			}
		};
		await use(fixture);
	},

	listApiKeys: async ({}, use) => {
		await use(async () => {
			const res = await apiCall('GET', '/api-keys');
			if (!res.ok) {
				throw new Error(`listApiKeys failed: ${res.status} ${await res.text()}`);
			}
			const data = (await res.json()) as unknown;
			if (!Array.isArray(data)) {
				throw new Error('listApiKeys failed: expected array response from /api-keys');
			}
			return data as ApiKeyListItem[];
		});
	},

	discoverWithApiKey: async ({}, use) => {
		await use(async (indexName: string, apiKey: string) => {
			const response = await fetch(
				`${fixtureEnv.apiUrl}/discover?index=${encodeURIComponent(indexName)}`,
				{
					headers: {
						Authorization: `Bearer ${apiKey}`
					}
				}
			);

			let body: {
				vm?: string;
				flapjack_url?: string;
				ttl?: number;
				service_type?: string;
			} | null = null;
			try {
				body = (await response.json()) as {
					vm?: string;
					flapjack_url?: string;
					ttl?: number;
					service_type?: string;
				};
			} catch {
				body = null;
			}

			return {
				status: response.status,
				body
			};
		});
	},

	setBillingPlan: async ({}, use) => {
		let originalPlan: 'free' | 'shared' | null = null;

		const switchPlan: SetBillingPlanFn = async (plan) => {
			if (originalPlan === null) {
				originalPlan = await getCurrentBillingPlan();
			}
			if (originalPlan === plan) {
				return;
			}
			await updateBillingPlan(plan);
		};

		await use(switchPlan);

		if (originalPlan !== null) {
			await updateBillingPlan(originalPlan).catch(() => {
				/* ignore teardown failures */
			});
		}
	},

	setBillingPlanForCustomer: async ({}, use) => {
		await use(async (customerId, plan) => {
			await updateBillingPlan(plan, customerId);
		});
	},

	getAccountPayloadForToken: async ({}, use) => {
		await use(async (token) => {
			return getAccountPayloadForTokenWithRetries(token, 'GET /account');
		});
	},

	seedRecommendationsConfig: async ({ testRegion, _trackIndexForCleanup }, use) => {
		const seedSearchableIndex = createSeedSearchableIndexFactory({
			testRegion,
			apiCall,
			adminApiCall,
			getCustomerId,
			waitForSeededIndex,
			flapjackUrl: fixtureEnv.flapjackUrl
		});
		const factory: SeedRecommendationsConfigFn = async (name, region) => {
			await cleanupStaleFixtureIndexesOnce();
			const targetRegion = region ?? fixtureEnv.testRegion;
			if (targetRegion === testRegion) {
				try {
					await seedSearchableIndex(name);
				} catch (error) {
					const message = error instanceof Error ? error.message : String(error);
					if (!message.toLowerCase().includes('index limit reached')) {
						throw error;
					}
					await cleanupStaleFixtureIndexesOnce({ force: true });
					try {
						await seedSearchableIndex(name);
					} catch (retryError) {
						throw new Error(
							`seedRecommendationsConfig failed after forced stale-index cleanup retry: ${retryError instanceof Error ? retryError.message : String(retryError)}`
						);
					}
				}
			} else {
				const customerId = await getCustomerId();
				await createSeededIndex(customerId, name, targetRegion, fixtureEnv.flapjackUrl);
				await waitForSeededIndex(name);
			}
			_trackIndexForCleanup(name);
			return {
				indexName: name,
				primaryObjectID: 'doc-1',
				secondaryObjectID: 'doc-2',
				facetName: RECOMMENDATION_FIXTURE_FACET_NAME,
				facetValue: RECOMMENDATION_FIXTURE_FACET_VALUE,
				missingFacetValue: RECOMMENDATION_FIXTURE_MISSING_FACET_VALUE
			};
		};

		await use(factory);
	},

	seedSearchableIndex: async ({ testRegion }, use) => {
		const cleanupIndexes: string[] = [];
		const seedSearchableIndex = createSeedSearchableIndexFactory({
			testRegion,
			apiCall,
			adminApiCall,
			getCustomerId,
			waitForSeededIndex,
			flapjackUrl: fixtureEnv.flapjackUrl
		});
		const factory: SeedSearchableIndexFn = async (name) => {
			await cleanupStaleFixtureIndexesOnce();
			let result;
			try {
				result = await seedSearchableIndex(name);
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				if (!message.toLowerCase().includes('index limit reached')) {
					throw error;
				}
				await cleanupStaleFixtureIndexesOnce({ force: true });
				try {
					result = await seedSearchableIndex(name);
				} catch (retryError) {
					throw new Error(
						`seedSearchableIndex failed after forced stale-index cleanup retry: ${retryError instanceof Error ? retryError.message : String(retryError)}`
					);
				}
			}
			cleanupIndexes.push(name);
			return result;
		};

		await use(factory);

		// Teardown: delete seeded indexes. Flapjack index keys are VM-side and
		// do not expose key IDs for revocation through this API surface.
		for (const name of cleanupIndexes) {
			await apiCall('DELETE', `/indexes/${encodeURIComponent(name)}`, { confirm: true }).catch(
				() => {}
			);
		}
	},

	seedInvoice: async ({}, use) => {
		const factory: SeedInvoiceFn = async () => {
			// Prefer existing invoices to avoid generating unnecessary data.
			const invoices = await listInvoicesBestEffort();
			if (invoices.length > 0) {
				return { id: invoices[0].id };
			}
			// No invoices exist — generate a draft via admin API.
			return createDraftInvoice('2025-01');
		};
		await use(factory);
	},

	seedInvoiceWithPdfUrl: async ({}, use) => {
		const factory: SeedInvoiceWithPdfUrlFn = async () => {
			const invoices = await listInvoicesBestEffort();

			// Reuse an existing invoice that already has Stripe PDF metadata.
			for (const invoice of invoices) {
				const detail = await getInvoiceDetailForFixture(invoice.id);
				if (detail?.pdf_url) {
					return { id: detail.id };
				}
			}

			// Otherwise finalize a draft invoice to produce pdf_url.
			const draftInvoiceId =
				invoices.find((invoice) => invoice.status === 'draft')?.id ??
				(await createDraftInvoice('2025-01')).id;
			const finalizeRes = await adminApiCall(
				'POST',
				`/admin/invoices/${encodeURIComponent(draftInvoiceId)}/finalize`
			);
			if (!finalizeRes.ok) {
				throw new Error(
					`seedInvoiceWithPdfUrl failed: ${finalizeRes.status} ${await finalizeRes.text()}`
				);
			}
			const finalized = (await finalizeRes.json()) as InvoiceDetailApiItem;
			if (!finalized.pdf_url) {
				throw new Error('seedInvoiceWithPdfUrl failed: finalized invoice returned null pdf_url');
			}
			return { id: finalized.id };
		};
		await use(factory);
	}
});

export { expect };
/**
 * @module Stub summary for auth.setup.ts.
 */
/**
 * Auth setup — runs once before any test project that depends on it.
 *
 * Logs in through the real browser UI and saves the resulting browser state
 * (cookies) to .auth/user.json.  All customer-facing tests load that state
 * automatically so they start already authenticated.
 *
 * This file is an ARRANGE-phase shortcut (page.goto + form fill + storageState
 * are all allowed shortcuts per BROWSER_TESTING_STANDARDS_2.md).
 */

import { test as setup, expect, type Page } from '@playwright/test';
import {
	PLAYWRIGHT_STORAGE_STATE,
	resolveFixtureEnv,
	resolveRequiredFixtureUserCredentials
} from '../../playwright.config.contract';
import {
	FIXTURE_AUTH_API_RETRY_BUDGET_MS,
	bootstrapFixtureUserForKnownLoginFailure,
	formatFixtureSetupFailure,
	setupFailureDetailsFromError
} from './fixtures';
import { verifyFreshSignupEmail } from './onboarding-auth-shared';

type CustomerLoginAttemptResult = {
	reachedDashboard: boolean;
	currentPath: string;
	alertText: string | null;
	responseStatus?: number;
	responseUrl?: string;
};

const LOGIN_SETTLE_TIMEOUT_MS = 20_000;
const DELAYED_ALERT_CAPTURE_TIMEOUT_MS = 5_000;
const AUTH_SETUP_TIMEOUT_MS =
	LOGIN_SETTLE_TIMEOUT_MS * 2 +
	FIXTURE_AUTH_API_RETRY_BUDGET_MS * 2 +
	DELAYED_ALERT_CAPTURE_TIMEOUT_MS +
	15_000;

setup.setTimeout(AUTH_SETUP_TIMEOUT_MS);

/**
 * TODO: Document attemptCustomerLogin.
 */
async function attemptCustomerLogin(
	page: Page,
	email: string,
	password: string
): Promise<CustomerLoginAttemptResult> {
	await page.goto('/login');
	await page.getByLabel('Email').fill(email);
	await page.getByLabel('Password').fill(password);

	const loginResponsePromise = page
		.waitForResponse(
			(response) => response.request().method() === 'POST' && response.url().includes('/login'),
			{ timeout: LOGIN_SETTLE_TIMEOUT_MS }
		)
		.catch(() => null);

	await page.getByRole('button', { name: /log in/i }).click();

	const loginAlert = page.getByRole('alert');
	await Promise.race([
		page.waitForURL(/\/console/, { timeout: LOGIN_SETTLE_TIMEOUT_MS }),
		loginAlert.waitFor({ state: 'visible', timeout: LOGIN_SETTLE_TIMEOUT_MS })
	]).catch(() => undefined);

	const loginResponse = await loginResponsePromise;
	const reachedDashboard = /\/console/.test(page.url());
	let alertText = reachedDashboard ? null : await loginAlert.textContent().catch(() => null);
	if (!reachedDashboard && !alertText?.trim()) {
		await loginAlert
			.waitFor({ state: 'visible', timeout: DELAYED_ALERT_CAPTURE_TIMEOUT_MS })
			.catch(() => undefined);
		alertText = await loginAlert.textContent().catch(() => null);
	}

	return {
		reachedDashboard,
		currentPath: page.url(),
		alertText,
		responseStatus: loginResponse?.status(),
		responseUrl: loginResponse?.url()
	};
}

function toFailureAlertText(
	attempt: CustomerLoginAttemptResult,
	bootstrapAttempted: boolean
): string | null {
	if (!bootstrapAttempted) {
		return attempt.alertText;
	}

	const normalizedAlertText = attempt.alertText?.trim() || '(none)';
	return `${normalizedAlertText} (after fixture self-bootstrap retry)`;
}

function toBootstrapFailureAlertText(attempt: CustomerLoginAttemptResult, error: unknown): string {
	const normalizedAlertText = attempt.alertText?.trim() || '(none)';
	return `${normalizedAlertText} (fixture self-bootstrap failed: ${setupFailureDetailsFromError(error)})`;
}

setup('authenticate as customer', async ({ page }) => {
	const { email, password } = resolveRequiredFixtureUserCredentials(process.env);
	const fixtureEnv = resolveFixtureEnv(process.env);
	let finalLoginAttempt = await attemptCustomerLogin(page, email, password);
	let bootstrapAttempted = false;

	if (!finalLoginAttempt.reachedDashboard) {
		try {
			const bootstrapResult = await bootstrapFixtureUserForKnownLoginFailure({
				apiUrl: fixtureEnv.apiUrl,
				email,
				password,
				currentPath: finalLoginAttempt.currentPath,
				alertText: finalLoginAttempt.alertText,
				responseStatus: finalLoginAttempt.responseStatus,
				responseUrl: finalLoginAttempt.responseUrl
			});

			if (bootstrapResult.bootstrapped) {
				bootstrapAttempted = true;
				// Self-bootstrapped accounts land unverified. Email-verified
				// state is required downstream by customer-auth POST /indexes
				// (and any other route gated on it). Force-verify before
				// retrying login so subsequent specs can seed data.
				await verifyFreshSignupEmail(email);
				finalLoginAttempt = await attemptCustomerLogin(page, email, password);
			}
		} catch (error) {
			throw new Error(
				formatFixtureSetupFailure({
					setupName: 'Customer login setup',
					expectedPath: '/console',
					currentPath: finalLoginAttempt.currentPath,
					apiUrl: fixtureEnv.apiUrl,
					adminKey: fixtureEnv.adminKey,
					alertText: toBootstrapFailureAlertText(finalLoginAttempt, error),
					responseStatus: finalLoginAttempt.responseStatus,
					responseUrl: finalLoginAttempt.responseUrl
				})
			);
		}
	}

	if (!finalLoginAttempt.reachedDashboard) {
		throw new Error(
			formatFixtureSetupFailure({
				setupName: 'Customer login setup',
				expectedPath: '/console',
				currentPath: finalLoginAttempt.currentPath,
				apiUrl: fixtureEnv.apiUrl,
				adminKey: fixtureEnv.adminKey,
				alertText: toFailureAlertText(finalLoginAttempt, bootstrapAttempted),
				responseStatus: finalLoginAttempt.responseStatus,
				responseUrl: finalLoginAttempt.responseUrl
			})
		);
	}

	await expect(page.getByRole('heading', { name: 'Console' })).toBeVisible();

	await page.context().storageState({ path: PLAYWRIGHT_STORAGE_STATE.user });
});
/**
 * Admin auth setup — runs once before any admin test project.
 *
 * Logs into the admin panel through the real browser UI using the ADMIN_KEY
 * env var and saves the resulting browser state to .auth/admin.json.
 */

import { test as setup } from '@playwright/test';
import {
	PLAYWRIGHT_STORAGE_STATE,
	resolveFixtureEnv,
	resolveRequiredFixtureAdminKey
} from '../../playwright.config.contract';
import { formatFixtureSetupFailure } from './fixtures';

setup('authenticate as admin', async ({ page }) => {
	const adminKey = resolveRequiredFixtureAdminKey(process.env);
	const fixtureEnv = resolveFixtureEnv(process.env);

	await page.goto('/admin/login');

	await page.getByLabel('Admin key').fill(adminKey);

	const loginResponsePromise = page
		.waitForResponse(
			(response) =>
				response.request().method() === 'POST' && response.url().includes('/admin/login'),
			{ timeout: 10_000 }
		)
		.catch(() => null);

	await page.getByRole('button', { name: 'Log in' }).click();

	const loginAlert = page.getByRole('alert');
	await Promise.race([
		page.waitForURL(/\/admin\/fleet/, { timeout: 10_000 }),
		loginAlert.waitFor({ state: 'visible', timeout: 10_000 })
	]).catch(() => undefined);

	if (!/\/admin\/fleet/.test(page.url())) {
		const [alertText, loginResponse] = await Promise.all([
			loginAlert.textContent().catch(() => null),
			loginResponsePromise
		]);
		throw new Error(
			formatFixtureSetupFailure({
				setupName: 'Admin login setup',
				expectedPath: '/admin/fleet',
				currentPath: page.url(),
				apiUrl: fixtureEnv.apiUrl,
				adminKey: fixtureEnv.adminKey,
				alertText,
				responseStatus: loginResponse?.status(),
				responseUrl: loginResponse?.url()
			})
		);
	}

	await page.context().storageState({ path: PLAYWRIGHT_STORAGE_STATE.admin });
});
/**
 * Onboarding auth setup — runs once before the chromium:onboarding project.
 *
 * Creates a brand-new customer account through the shared onboarding setup
 * helper and saves that authenticated fresh-user session to
 * `tests/fixtures/.auth/onboarding.json`.
 */

import path from 'path';
import { fileURLToPath } from 'url';
import { registerFreshOnboardingAccount } from './onboarding-auth-shared';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ONBOARDING_AUTH_FILE = path.join(__dirname, '.auth/onboarding.json');

registerFreshOnboardingAccount('create fresh account for onboarding', ONBOARDING_AUTH_FILE);
/**
 * Customer journeys auth setup — runs once before the chromium:customer-journeys project.
 *
 * Creates a second brand-new customer account through the shared onboarding
 * setup helper so the long-form journey spec does not consume the same fresh
 * storage state that onboarding.spec.ts relies on.
 */

import path from 'path';
import { fileURLToPath } from 'url';
import { registerFreshOnboardingAccount } from './onboarding-auth-shared';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CUSTOMER_JOURNEYS_AUTH_FILE = path.join(__dirname, '.auth/customer-journeys.json');

registerFreshOnboardingAccount(
	'create fresh account for customer journeys',
	CUSTOMER_JOURNEYS_AUTH_FILE
);
#!/usr/bin/env bash
# playwright_local_stack.sh — Start local API + web for Playwright runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_DIR="$REPO_ROOT/.local"
API_LOG_PATH="$LOCAL_DIR/playwright_api.log"
PLAYWRIGHT_API_PORT="${PLAYWRIGHT_API_PORT:-3001}"
DEFAULT_PLAYWRIGHT_API_BASE_URL="http://127.0.0.1:${PLAYWRIGHT_API_PORT}"
API_BASE_URL="${API_BASE_URL:-${API_URL:-$DEFAULT_PLAYWRIGHT_API_BASE_URL}}"
API_URL="${API_URL:-$API_BASE_URL}"
API_HEALTH_URL="${API_BASE_URL%/}/health"
LISTEN_ADDR="${LISTEN_ADDR:-127.0.0.1:${PLAYWRIGHT_API_PORT}}"
API_START_TIMEOUT_SECONDS="${PLAYWRIGHT_API_READY_TIMEOUT_SECONDS:-180}"
FORCE_API_RESTART="${PLAYWRIGHT_FORCE_API_RESTART:-0}"

parse_port_from_http_url() {
	local url="$1"
	local hostport port
	hostport="$(printf '%s' "$url" | sed -E 's#^https?://([^/]+)/?.*$#\1#')"
	port="${hostport##*:}"

	if ! [[ "$port" =~ ^[0-9]+$ ]]; then
		echo "[playwright_local_stack] ERROR: could not parse port from URL=$url" >&2
		exit 1
	fi

	printf '%s\n' "$port"
}

FLAPJACK_URL="${FLAPJACK_URL:-${LOCAL_DEV_FLAPJACK_URL:-http://127.0.0.1:7700}}"
FLAPJACK_PORT="$(parse_port_from_http_url "$FLAPJACK_URL")"
FLAPJACK_HEALTH_URL="${FLAPJACK_URL%/}/health"
FLAPJACK_EXPERIMENTS_API_URL="${FLAPJACK_URL%/}/2/abtests"
FLAPJACK_START_TIMEOUT_SECONDS="${PLAYWRIGHT_FLAPJACK_READY_TIMEOUT_SECONDS:-30}"
FLAPJACK_LOG_PATH="$LOCAL_DIR/playwright_flapjack.log"
FLAPJACK_DATA_DIR="${PLAYWRIGHT_FLAPJACK_DATA_DIR:-$LOCAL_DIR/flapjack-data-playwright-$FLAPJACK_PORT}"
FLAPJACK_EXPERIMENTS_DATA_DIR="$FLAPJACK_DATA_DIR/.experiments"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=lib/health.sh
source "$SCRIPT_DIR/lib/health.sh"
# shellcheck source=lib/flapjack_binary.sh
source "$SCRIPT_DIR/lib/flapjack_binary.sh"

export PLAYWRIGHT_API_PORT
export API_BASE_URL
export API_URL
export LISTEN_ADDR
load_env_file "$REPO_ROOT/.env.local"
export FLAPJACK_ADMIN_KEY="${FLAPJACK_ADMIN_KEY:-$DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY}"

log() { echo "[playwright_local_stack] $*"; }

if [ "${1:-}" = "--force-api-restart" ]; then
	FORCE_API_RESTART="1"
	shift
fi

mkdir -p "$LOCAL_DIR"

api_pid=""
started_api="0"
flapjack_pid=""
started_flapjack="0"
web_pid=""
started_web="0"

cleanup() {
	if [ "$started_web" = "1" ] && [ -n "$web_pid" ] && kill -0 "$web_pid" 2>/dev/null; then
		kill "$web_pid" 2>/dev/null || true
		wait "$web_pid" 2>/dev/null || true
	fi
	if [ "$started_flapjack" = "1" ] && [ -n "$flapjack_pid" ] && kill -0 "$flapjack_pid" 2>/dev/null; then
		kill "$flapjack_pid" 2>/dev/null || true
		wait "$flapjack_pid" 2>/dev/null || true
	fi
	if [ "$started_api" = "1" ] && [ -n "$api_pid" ] && kill -0 "$api_pid" 2>/dev/null; then
		kill "$api_pid" 2>/dev/null || true
		wait "$api_pid" 2>/dev/null || true
	fi
}

handle_shutdown() {
	cleanup
	exit 0
}

trap cleanup EXIT
trap handle_shutdown INT TERM

# TODO: Document kill_owned_api_listener_for_restart.
kill_owned_api_listener_for_restart() {
	local api_hostport api_port listening_pids pid command_line
	api_hostport="$(printf '%s' "$API_HEALTH_URL" | sed -E 's#^https?://([^/]+)/?.*$#\1#')"
	api_port="${api_hostport##*:}"

	if ! [[ "$api_port" =~ ^[0-9]+$ ]]; then
		echo "[playwright_local_stack] ERROR: could not parse API port from API_HEALTH_URL=$API_HEALTH_URL" >&2
		exit 1
	fi

	listening_pids="$(lsof -tiTCP:"$api_port" -sTCP:LISTEN 2>/dev/null || true)"
	if [ -z "$listening_pids" ]; then
		return
	fi

	for pid in $listening_pids; do
		command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
		if [[ "$command_line" == *"fjcloud-api"* ]] || \
			[[ "$command_line" == *"cargo run --manifest-path infra/Cargo.toml -p api"* ]] || \
			[[ "$command_line" == *"cargo run -p api --manifest-path infra/Cargo.toml"* ]] || \
			[[ "$command_line" == *"/target/debug/api"* ]] || \
			[[ "$command_line" == *"/target/release/api"* ]]; then
			kill "$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
			continue
		fi

		echo "[playwright_local_stack] ERROR: refusing to kill non-fjcloud process on API port $api_port (pid $pid: $command_line)" >&2
		exit 1
	done
}

# TODO: Document reset_playwright_experiments_storage.
reset_playwright_experiments_storage() {
	# The Playwright stack owns this hidden Flapjack system index. Rebuilding it
	# avoids stale Tantivy metadata from an interrupted prior local browser run.
	rm -rf "$FLAPJACK_EXPERIMENTS_DATA_DIR"
}

# TODO: Document ensure_flapjack_experiments_api_ready.
ensure_flapjack_experiments_api_ready() {
	local response_file http_status
	response_file="$(mktemp "$LOCAL_DIR/flapjack-experiments-bootstrap.XXXXXX")"
	http_status="$(
		curl -sS -o "$response_file" -w '%{http_code}' \
			-X GET "$FLAPJACK_EXPERIMENTS_API_URL" \
			-H "X-Algolia-Application-Id: flapjack" \
			-H "X-Algolia-API-Key: ${FLAPJACK_ADMIN_KEY}"
	)" || {
		echo "[playwright_local_stack] ERROR: failed to verify Flapjack experiments API readiness" >&2
		cat "$response_file" >&2 2>/dev/null || true
		rm -f "$response_file"
		exit 1
	}

	case "$http_status" in
		200)
			rm -f "$response_file"
			;;
		*)
			echo "[playwright_local_stack] ERROR: experiments API readiness returned HTTP $http_status" >&2
			cat "$response_file" >&2 2>/dev/null || true
			rm -f "$response_file"
			exit 1
			;;
	esac
}

# TODO: Document ensure_local_flapjack_ready.
ensure_local_flapjack_ready() {
	local flapjack_bin listening_pids

	if curl -fsS "$FLAPJACK_HEALTH_URL" >/dev/null 2>&1; then
		return
	fi

	listening_pids="$(lsof -tiTCP:"$FLAPJACK_PORT" -sTCP:LISTEN 2>/dev/null || true)"
	if [ -n "$listening_pids" ]; then
		echo "[playwright_local_stack] ERROR: flapjack health check failed at $FLAPJACK_HEALTH_URL while port $FLAPJACK_PORT is already in use (pid(s): $listening_pids)" >&2
		echo "[playwright_local_stack] ERROR: stop the stale listener or use a different FLAPJACK_URL before running Playwright." >&2
		exit 1
	fi

	flapjack_bin="$(find_restart_ready_flapjack_binary "${FLAPJACK_DEV_DIR:-}" || true)"
	if [ -z "$flapjack_bin" ] || [ ! -x "$flapjack_bin" ]; then
		echo "[playwright_local_stack] ERROR: flapjack is not healthy at $FLAPJACK_HEALTH_URL and no local flapjack binary was found." >&2
		echo "[playwright_local_stack] ERROR: set FLAPJACK_DEV_DIR to your flapjack_dev checkout and run: cargo build -p flapjack-server" >&2
		exit 1
	fi

	mkdir -p "$FLAPJACK_DATA_DIR"
	reset_playwright_experiments_storage
	FLAPJACK_ADMIN_KEY="$FLAPJACK_ADMIN_KEY" \
		nohup "$flapjack_bin" \
			--port "$FLAPJACK_PORT" \
			--data-dir "$FLAPJACK_DATA_DIR" \
			< /dev/null > "$FLAPJACK_LOG_PATH" 2>&1 &
	flapjack_pid="$!"
	started_flapjack="1"

	if ! wait_for_health "$FLAPJACK_HEALTH_URL" "playwright flapjack" "$FLAPJACK_START_TIMEOUT_SECONDS"; then
		echo "[playwright_local_stack] ERROR: flapjack did not become ready at $FLAPJACK_HEALTH_URL" >&2
		tail -n 200 "$FLAPJACK_LOG_PATH" 2>/dev/null || true
		exit 1
	fi
}

if [ "$FORCE_API_RESTART" = "1" ]; then
	kill_owned_api_listener_for_restart
fi

ensure_local_flapjack_ready
ensure_flapjack_experiments_api_ready

if ! curl -fsS "$API_HEALTH_URL" >/dev/null 2>&1; then
	bash "$SCRIPT_DIR/api-dev.sh" >"$API_LOG_PATH" 2>&1 &
	api_pid="$!"
	started_api="1"

	for _ in $(seq 1 "$API_START_TIMEOUT_SECONDS"); do
		if curl -fsS "$API_HEALTH_URL" >/dev/null 2>&1; then
			break
		fi
		sleep 1
	done

	if ! curl -fsS "$API_HEALTH_URL" >/dev/null 2>&1; then
		echo "[playwright_local_stack] ERROR: API did not become ready at $API_HEALTH_URL" >&2
		tail -n 200 "$API_LOG_PATH" 2>/dev/null || true
		exit 1
	fi
fi

bash "$SCRIPT_DIR/web-dev.sh" "$@" &
web_pid="$!"
started_web="1"

set +e
wait "$web_pid"
web_status="$?"
set -e
started_web="0"
exit "$web_status"
```
