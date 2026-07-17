# Owner Snapshot

Captured at UTC: 2026-07-09T20:06:58Z

## Files

- web/playwright.config.ts
- web/playwright.config.contract.ts
- web/tests/fixtures/fixtures.ts
- web/tests/fixtures/auth.setup.ts
- web/tests/fixtures/admin.auth.setup.ts
- web/tests/fixtures/onboarding.auth.setup.ts
- web/tests/fixtures/customer-journeys.auth.setup.ts
- scripts/playwright_local_stack.sh

## Contents

### web/playwright.config.ts

```
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

```

### web/playwright.config.contract.ts

```
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

```

### web/tests/fixtures/fixtures.ts

```
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

```

### web/tests/fixtures/auth.setup.ts

```
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

```

### web/tests/fixtures/admin.auth.setup.ts

```
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

```

### web/tests/fixtures/onboarding.auth.setup.ts

```
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

```

### web/tests/fixtures/customer-journeys.auth.setup.ts

```
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

```

### scripts/playwright_local_stack.sh

```
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

