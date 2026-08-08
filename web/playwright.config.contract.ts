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
export const PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION_ENV = 'PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION';
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
// Covers Flapjack/migration preflight plus the stack's separate 180-second API readiness window.
export const PLAYWRIGHT_WEB_SERVER_TIMEOUT_MS = 600_000;
export const PLAYWRIGHT_PROVIDER_PARITY_SHUTDOWN_TIMEOUT_MS = 30_000;
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
	gracefulShutdown?: {
		signal: 'SIGINT' | 'SIGTERM';
		timeout: number;
	};
};

export type PlaywrightRuntimeContract = {
	baseURL: string;
	webServerEnv: Record<string, string>;
	webServer: PlaywrightWebServerContract | undefined;
};

const API_BACKED_PUBLIC_SPEC_NAMES = new Set(['public-infrastructure.spec.ts']);
const PLAYWRIGHT_SPEC_LOCATION_SUFFIX_PATTERN = /:\d+(?::\d+)?$/;
const EMAIL_VERIFICATION_PROJECT_NAME = 'chromium:email-verification';
const SOURCE_MIGRATION_PROVIDER_PARITY_GREP = 'source migration provider parity';
const SOURCE_MIGRATION_PROVIDER_PARITY_SPEC = 'source_migration_provider_parity.spec.ts';

function publicSpecRequiresApiStack(specFilter: string): boolean {
	const normalizedFilter = specFilter
		.replaceAll('\\', '/')
		.replace(PLAYWRIGHT_SPEC_LOCATION_SUFFIX_PATTERN, '');
	const specName = normalizedFilter.slice(normalizedFilter.lastIndexOf('/') + 1);
	return API_BACKED_PUBLIC_SPEC_NAMES.has(specName);
}

function getSelectedPlaywrightProjects(argv: string[]): string[] {
	const selectedProjects: string[] = [];
	for (let index = 0; index < argv.length; index += 1) {
		const arg = argv[index];
		if (arg === '--project' && argv[index + 1]) {
			let projectIndex = index + 1;
			while (projectIndex < argv.length && !argv[projectIndex].startsWith('-')) {
				selectedProjects.push(argv[projectIndex]);
				projectIndex += 1;
			}
			index = projectIndex - 1;
			continue;
		}
		if (arg.startsWith('--project=')) {
			selectedProjects.push(arg.slice('--project='.length));
		}
	}
	return selectedProjects;
}

function wildcardProjectPatternMatches(pattern: string, projectName: string): boolean {
	const escapedPattern = pattern.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replaceAll('*', '.*');
	return new RegExp(`^${escapedPattern}$`).test(projectName);
}

function wildcardProjectSelectionTargetsEmailVerification(selectedProjects: string[]): boolean {
	return selectedProjects.some(
		(projectName) =>
			projectName.includes('*') &&
			projectName !== EMAIL_VERIFICATION_PROJECT_NAME &&
			wildcardProjectPatternMatches(projectName, EMAIL_VERIFICATION_PROJECT_NAME)
	);
}

function isSoleEmailVerificationProjectSelection(argv: string[]): boolean {
	const selectedProjects = getSelectedPlaywrightProjects(argv);
	if (wildcardProjectSelectionTargetsEmailVerification(selectedProjects)) {
		throw new Error(
			`${EMAIL_VERIFICATION_PROJECT_NAME} must be selected exactly; wildcard project selection is not allowed for email verification mode`
		);
	}
	return selectedProjects.length === 1 && selectedProjects[0] === EMAIL_VERIFICATION_PROJECT_NAME;
}

/**
 * Return true only when the requested public-project specs can run against the
 * web server without the local API stack.
 */
function isPublicOnlyPlaywrightSelection(argv: string[]): boolean {
	if (!getSelectedPlaywrightProjects(argv).includes('chromium:public')) {
		return false;
	}

	const specFilters = argv.filter((arg) => arg.includes('.spec.ts'));
	if (specFilters.length === 0) {
		// Fail closed when chromium:public is selected without concrete spec paths.
		// Grep-only reruns can still include API-backed owners such as
		// public-infrastructure.spec.ts, and argv text alone cannot disambiguate them.
		return false;
	}

	return specFilters.every(
		(filterArg) => filterArg.includes('public-') && !publicSpecRequiresApiStack(filterArg)
	);
}

function isSourceMigrationProviderParitySelection(argv: string[]): boolean {
	return argv.some((argument) => {
		if (argument.includes(SOURCE_MIGRATION_PROVIDER_PARITY_GREP)) return true;
		const normalizedArgument = argument
			.replaceAll('\\', '/')
			.replace(PLAYWRIGHT_SPEC_LOCATION_SUFFIX_PATTERN, '');
		return normalizedArgument.endsWith(`/${SOURCE_MIGRATION_PROVIDER_PARITY_SPEC}`);
	});
}

const PLAYWRIGHT_DEFAULT_PORT_HASH_MIN = 5600;
const PLAYWRIGHT_DEFAULT_PORT_HASH_SPAN = 2000;
const PLAYWRIGHT_DEFAULT_API_PORT_HASH_MIN = 7600;
// Chromium blocks these ports inside the derived web band for all HTTP requests.
// Advancing to the next safe port preserves deterministic workspace isolation.
const CHROMIUM_BLOCKED_PLAYWRIGHT_WEB_PORTS = new Set([
	6000, 6566, 6665, 6666, 6667, 6668, 6669, 6697
]);
// Flapjack band sits above web (5600–7599), API (7600–9599), and the API's S3 sidecar
// (apiPort+1, ≤9600) so the three workspace-derived ports — which all share the same
// hash offset — never collide. 9700 + offset(0–1999) → 9700–11699, safely below 65535.
const PLAYWRIGHT_DEFAULT_FLAPJACK_PORT_HASH_MIN = 9700;
// The manual stack's database band is the fourth span above flapjack
// (17700–19699). scripts/lib/playwright_port_plan.sh mirrors the same fact as
// `flapjack + (4 * PLAYWRIGHT_DEFAULT_PORT_HASH_SPAN)`, so this must stay
// expressed in spans rather than a second literal: a changed span has to move
// both runtimes or neither.
const PLAYWRIGHT_LOCAL_DB_PORT_SPANS_ABOVE_FLAPJACK = 4;
// Source-provider bands sit above the manual stack's database band (at most
// 19699). Provider-parity runs start all five HTTP services together, so
// reusing the web/API bands would make a clean invocation fail on its own
// host-port collision.
const PLAYWRIGHT_DEFAULT_MEILISEARCH_PORT_HASH_MIN = 19700;
const PLAYWRIGHT_DEFAULT_TYPESENSE_PORT_HASH_MIN = 21700;
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
	let derivedPort = PLAYWRIGHT_DEFAULT_PORT_HASH_MIN + portOffset;
	while (CHROMIUM_BLOCKED_PLAYWRIGHT_WEB_PORTS.has(derivedPort)) {
		derivedPort += 1;
	}
	return derivedPort;
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

export function resolveDefaultPlaywrightLocalDbPort(workspacePath: string = process.cwd()): number {
	return (
		resolveDefaultPlaywrightFlapjackPort(workspacePath) +
		PLAYWRIGHT_LOCAL_DB_PORT_SPANS_ABOVE_FLAPJACK * PLAYWRIGHT_DEFAULT_PORT_HASH_SPAN
	);
}

export function resolveDefaultPlaywrightMeilisearchPort(
	workspacePath: string = process.cwd()
): number {
	const normalizedWorkspacePath = workspacePath.trim();
	if (normalizedWorkspacePath.length === 0) {
		return 7710;
	}
	const portOffset = hashStringFNV1A(normalizedWorkspacePath) % PLAYWRIGHT_DEFAULT_PORT_HASH_SPAN;
	return PLAYWRIGHT_DEFAULT_MEILISEARCH_PORT_HASH_MIN + portOffset;
}

export function resolveDefaultPlaywrightTypesensePort(
	workspacePath: string = process.cwd()
): number {
	const normalizedWorkspacePath = workspacePath.trim();
	if (normalizedWorkspacePath.length === 0) {
		return 8108;
	}
	const portOffset = hashStringFNV1A(normalizedWorkspacePath) % PLAYWRIGHT_DEFAULT_PORT_HASH_SPAN;
	return PLAYWRIGHT_DEFAULT_TYPESENSE_PORT_HASH_MIN + portOffset;
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

function resolvePlaywrightSourceProviderPort(
	processEnv: Record<string, string | undefined>,
	envName: 'LOCAL_MEILISEARCH_PORT' | 'LOCAL_TYPESENSE_PORT',
	defaultPort: number
): number {
	const configuredPort = processEnv[envName]?.trim();
	if (!configuredPort) {
		return defaultPort;
	}
	if (!/^\d+$/.test(configuredPort)) {
		throw new Error(
			`${envName} must be an integer TCP port when set (received "${configuredPort}")`
		);
	}
	const parsedPort = Number(configuredPort);
	if (!Number.isInteger(parsedPort) || parsedPort < 1024 || parsedPort > 65535) {
		throw new Error(
			`${envName} must be between 1024 and 65535 when set (received "${configuredPort}")`
		);
	}
	return parsedPort;
}

function enableSourceProviderComposeProfile(processEnv: Record<string, string | undefined>): void {
	const profiles = (processEnv.COMPOSE_PROFILES ?? '')
		.split(',')
		.map((profile) => profile.trim())
		.filter(Boolean);
	if (!profiles.includes('source-providers')) {
		profiles.push('source-providers');
	}
	processEnv.COMPOSE_PROFILES = profiles.join(',');
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
		name: 'chromium:security-headers',
		testMatch: /e2e-ui\/full\/security_headers\.spec\.ts/,
		use: { desktopBrowser: 'chromium' }
	},
	{
		// Hermetic browser contracts: every request including the document is
		// fulfilled by page.route, so these need no application, no database and
		// no host ports. They must stay dependency-free — adding a `dependencies`
		// entry here would couple them to the contended local stack and defeat
		// the reason they exist.
		name: 'chromium:contract',
		testMatch: /e2e-ui\/contract\/.+\.spec\.ts/,
		use: { desktopBrowser: 'chromium' }
	},
	{
		name: EMAIL_VERIFICATION_PROJECT_NAME,
		testMatch: /e2e-ui\/full\/auth-end-effects\.spec\.ts/,
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
			/e2e-ui\/(smoke|full)\/(?!accessibility\.|admin|public-|onboarding\.|customer-journeys\.|signup_to_paid_invoice\.|security_headers\.).+\.spec\.ts/,
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
	},
	{
		name: 'chromium:accessibility',
		testMatch: /e2e-ui\/full\/accessibility\.spec\.ts/,
		dependencies: ['setup:user', 'setup:admin'],
		use: {
			desktopBrowser: 'chromium'
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

const INVALID_DATABASE_URL_MESSAGE =
	'DATABASE_URL must be a valid PostgreSQL URL for local Playwright runs';
const NON_LOOPBACK_DATABASE_URL_MESSAGE =
	'DATABASE_URL must be a loopback PostgreSQL URL for local Playwright runs';

// Same loopback set the two consumers of this value already enforce:
// require_local_database_url in scripts/playwright_local_stack.sh and
// requireLoopbackDatabaseUrl in web/tests/fixtures/fixtures.ts. WHATWG URL
// reports IPv6 hosts bracketed, the shell guard's urlsplit reports them bare,
// so accept both spellings rather than a single runtime's rendering.
function databaseUrlHostnameIsLoopback(hostname: string): boolean {
	return (
		hostname === 'localhost' ||
		hostname === '::1' ||
		hostname === '[::1]' ||
		/^127(?:\.\d{1,3}){3}$/.test(hostname)
	);
}

function databaseUrlWithPort(rawUrl: string, port: number): string {
	// `new URL` throws a bare `TypeError: Invalid URL` on malformed input, which
	// surfaces during config load with no mention of the offending variable.
	// Convert it to the same named error the scheme/host guard raises so every
	// rejection path names DATABASE_URL.
	let parsed: URL;
	try {
		parsed = new URL(rawUrl);
	} catch {
		throw new Error(INVALID_DATABASE_URL_MESSAGE);
	}
	if (!['postgres:', 'postgresql:'].includes(parsed.protocol) || !parsed.hostname) {
		throw new Error(INVALID_DATABASE_URL_MESSAGE);
	}
	// Rewriting the port of a remote host would point the operator's database
	// credentials at a workspace-derived port nobody configured on that host.
	// The stack's own non-loopback refusal is skipped whenever an API is already
	// healthy, and runFixtureSql applies no loopback check at all, so this is the
	// only gate on the rewritten value for that path. Fail closed here instead.
	if (!databaseUrlHostnameIsLoopback(parsed.hostname)) {
		throw new Error(NON_LOOPBACK_DATABASE_URL_MESSAGE);
	}
	parsed.port = String(port);
	return parsed.toString();
}

export function applyPlaywrightProcessEnvDefaults({
	processEnv,
	repoEnv,
	webEnv
}: ApplyPlaywrightProcessEnvDefaultsParams): void {
	const localApiUrl =
		processEnv.API_URL ??
		processEnv.API_BASE_URL ??
		webEnv.API_URL ??
		webEnv.API_BASE_URL ??
		repoEnv.API_URL ??
		repoEnv.API_BASE_URL;
	const allowLocalCredentialFallbacks =
		!isRemoteTargetOptInActive(processEnv) || isLoopbackHttpUrl(localApiUrl);
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

function isLoopbackHttpUrl(rawUrl: string | undefined): boolean {
	if (!rawUrl?.trim()) {
		return false;
	}
	try {
		const parsed = new URL(rawUrl);
		return ['http:', 'https:'].includes(parsed.protocol) && LOOPBACK_HOSTS.has(parsed.hostname);
	} catch {
		return false;
	}
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
	const isSourceMigrationProviderParity = isSourceMigrationProviderParitySelection(argv);
	const hasExplicitBaseUrl = Boolean(processEnv.BASE_URL && processEnv.BASE_URL.trim().length > 0);
	const processApiBaseUrl = processEnv.API_BASE_URL?.trim();
	const processApiUrl = processEnv.API_URL?.trim();
	const processDatabaseUrl = processEnv.DATABASE_URL?.trim();
	const apiBaseUrlIsFileBacked =
		Boolean(processApiBaseUrl) &&
		(processApiBaseUrl === repoEnv.API_BASE_URL?.trim() ||
			processApiBaseUrl === webEnv.API_BASE_URL?.trim());
	const apiUrlIsFileBacked =
		Boolean(processApiUrl) &&
		(processApiUrl === repoEnv.API_URL?.trim() || processApiUrl === webEnv.API_URL?.trim());
	const databaseUrlIsFileBacked =
		Boolean(processDatabaseUrl) &&
		(processDatabaseUrl === repoEnv.DATABASE_URL?.trim() ||
			processDatabaseUrl === webEnv.DATABASE_URL?.trim());
	const requiresEmailVerification =
		!hasExplicitBaseUrl && isSoleEmailVerificationProjectSelection(argv);
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
	const shouldStartSpawnedLocalWebServer =
		shouldStartExplicitNoDepsWebServer || !hasExplicitBaseUrl;
	if (isSourceMigrationProviderParity && shouldStartSpawnedLocalWebServer) {
		const meilisearchPort = resolvePlaywrightSourceProviderPort(
			processEnv,
			'LOCAL_MEILISEARCH_PORT',
			resolveDefaultPlaywrightMeilisearchPort(workspacePath)
		);
		const typesensePort = resolvePlaywrightSourceProviderPort(
			processEnv,
			'LOCAL_TYPESENSE_PORT',
			resolveDefaultPlaywrightTypesensePort(workspacePath)
		);
		enableSourceProviderComposeProfile(processEnv);
		processEnv.LOCAL_MEILISEARCH_PORT = String(meilisearchPort);
		processEnv.LOCAL_TYPESENSE_PORT = String(typesensePort);
		processEnv.MEILI_TEST_SECRET_CANARY ??= `playwright-meili-canary-${randomUUID()}`;
		processEnv.TYPESENSE_STAGE2_BOOTSTRAP_CANARY ??= `playwright-typesense-canary-${randomUUID()}`;
	}
	if (!hasExplicitBaseUrl) {
		processEnv.BASE_URL = baseURL;
		// Local spawned-stack runs must ignore static API_BASE_URL/API_URL values
		// from shared .env.local to prevent cross-worktree port contention. Shells
		// that export .env.local materialize those values in processEnv, so matching
		// file-backed values are defaults rather than deliberate process overrides.
		if (
			!processEnv.API_BASE_URL ||
			processEnv.API_BASE_URL.trim().length === 0 ||
			apiBaseUrlIsFileBacked
		) {
			processEnv.API_BASE_URL = defaultApiBaseUrl;
		}
		if (!processEnv.API_URL || processEnv.API_URL.trim().length === 0 || apiUrlIsFileBacked) {
			processEnv.API_URL = defaultApiBaseUrl;
		}
		if (
			!processEnv[PLAYWRIGHT_API_PORT_ENV] ||
			processEnv[PLAYWRIGHT_API_PORT_ENV]?.trim().length === 0
		) {
			processEnv[PLAYWRIGHT_API_PORT_ENV] = String(apiPort);
		}
		if (processEnv.DATABASE_URL && databaseUrlIsFileBacked) {
			processEnv.DATABASE_URL = databaseUrlWithPort(
				processEnv.DATABASE_URL,
				resolveDefaultPlaywrightLocalDbPort(workspacePath)
			);
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
	if (requiresEmailVerification) {
		processEnv[PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION_ENV] = '1';
	} else {
		delete processEnv[PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION_ENV];
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
	const localEmailVerificationEnv = requiresEmailVerification
		? {
				[PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION_ENV]: '1',
				SKIP_EMAIL_VERIFICATION: undefined,
				API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION: undefined
			}
		: {
				SKIP_EMAIL_VERIFICATION: '1',
				API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION: '1'
			};
	const spawnedLocalWebServerEnv = shouldStartSpawnedLocalWebServer
		? {
				ENVIRONMENT: 'local',
				FJCLOUD_ALLOW_LOOPBACK_SOURCE_ORIGINS: '1',
				...(isSourceMigrationProviderParity
					? {
							FJCLOUD_ALGOLIA_MIGRATION_ENABLED: 'true',
							FJ_ENABLE_MEILISEARCH_PREVIEW_LOOPBACK: '1',
							FJ_ENABLE_TYPESENSE_PREVIEW_LOOPBACK: '1',
							PLAYWRIGHT_FLAPJACK_DATA_DIR: `../.local/flapjack-data-source-migration-provider-parity-${flapjackPort}`
						}
					: {})
			}
		: {};
	const webServerEnv = sanitizeWebServerEnv({
		...repoEnv,
		...webEnv,
		...processEnv,
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
		// {local,dev,development}. The ENVIRONMENT flag and loopback-source
		// opt-in belong only on spawned local servers; explicit BASE_URL runs
		// keep the verification bypass values for helper parity, but must not
		// advertise the migrate-loopback exception to an already-running or
		// remote target.
		...spawnedLocalWebServerEnv,
		...localEmailVerificationEnv
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
						timeout: PLAYWRIGHT_WEB_SERVER_TIMEOUT_MS,
						...(isSourceMigrationProviderParity
							? {
									gracefulShutdown: {
										signal: 'SIGTERM' as const,
										timeout: PLAYWRIGHT_PROVIDER_PARITY_SHUTDOWN_TIMEOUT_MS
									}
								}
							: {})
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

function assertSafeRemoteTargetUrl(varName: string, parsed: URL): void {
	if (parsed.username || parsed.password) {
		throw new Error(`${varName} must not embed URL credentials when ${REMOTE_TARGET_OPT_IN_ENV}=1`);
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
