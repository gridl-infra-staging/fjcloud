import { randomUUID } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { requireNonBlankString, requireNonEmptyString } from './tests/fixtures/contract-guards';

export const DEFAULT_PLAYWRIGHT_BASE_URL = 'http://localhost:5173';
export const DEFAULT_PLAYWRIGHT_ADMIN_KEY = `playwright-local-admin-${randomUUID()}`;
export const PLAYWRIGHT_WEB_SERVER_COMMAND =
	'../scripts/web-dev.sh --host 127.0.0.1 --port 5173 --strictPort';
export const PLAYWRIGHT_STORAGE_STATE = {
	user: 'tests/fixtures/.auth/user.json',
	onboarding: 'tests/fixtures/.auth/onboarding.json',
	customerJourneys: 'tests/fixtures/.auth/customer-journeys.json',
	admin: 'tests/fixtures/.auth/admin.json'
} as const;
export const PLAYWRIGHT_DESKTOP_DEVICE = {
	chromium: 'Desktop Chrome',
	firefox: 'Desktop Firefox',
	webkit: 'Desktop Safari'
} as const;
export type PlaywrightDesktopBrowser = keyof typeof PLAYWRIGHT_DESKTOP_DEVICE;

// Fixture-side env defaults — single source of truth for values previously
// scattered across fixtures.ts, searchable-index.ts, auth.setup.ts, etc.
export const DEFAULT_API_URL = 'http://localhost:3001';
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
};

export type ApplyPlaywrightProcessEnvDefaultsParams = Omit<
	ResolvePlaywrightRuntimeParams,
	'fallbackJwtSecret'
>;

export type PlaywrightWebServerContract = {
	command: string;
	env: Record<string, string>;
	url: string;
	reuseExistingServer: false;
	timeout: number;
};

export type PlaywrightRuntimeContract = {
	baseURL: string;
	webServerEnv: Record<string, string>;
	webServer: PlaywrightWebServerContract | undefined;
};

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
		name: 'chromium',
		testMatch:
			/e2e-ui\/(smoke|full)\/(?!admin|public-|onboarding\.|customer-journeys\.).+\.spec\.ts/,
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
		name: 'firefox:public',
		testMatch: /e2e-ui\/full\/public-pages\.spec\.ts/,
		use: { desktopBrowser: 'firefox' }
	},
	{
		name: 'firefox:smoke',
		testMatch: /e2e-ui\/smoke\/(auth|dashboard|indexes)\.spec\.ts/,
		dependencies: ['setup:user'],
		use: {
			desktopBrowser: 'firefox',
			storageState: PLAYWRIGHT_STORAGE_STATE.user
		}
	},
	{
		name: 'webkit:public',
		testMatch: /e2e-ui\/full\/public-pages\.spec\.ts/,
		use: { desktopBrowser: 'webkit' }
	},
	{
		name: 'webkit:smoke',
		testMatch: /e2e-ui\/smoke\/(auth|dashboard|indexes)\.spec\.ts/,
		dependencies: ['setup:user'],
		use: {
			desktopBrowser: 'webkit',
			storageState: PLAYWRIGHT_STORAGE_STATE.user
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

function firstDefinedEnvValue(...values: Array<string | undefined>): string | undefined {
	return values.find((value) => value !== undefined && value !== '');
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

export function applyPlaywrightProcessEnvDefaults({
	processEnv,
	repoEnv,
	webEnv
}: ApplyPlaywrightProcessEnvDefaultsParams): void {
	// Terminal fallback to DEFAULT_PLAYWRIGHT_ADMIN_KEY ensures workers see the
	// same key that resolvePlaywrightRuntime passes to the web server when no
	// .env.local or explicit ADMIN_KEY is available.
	assignFirstDefinedEnvValue(
		processEnv,
		'E2E_ADMIN_KEY',
		processEnv.E2E_ADMIN_KEY,
		webEnv.E2E_ADMIN_KEY,
		repoEnv.E2E_ADMIN_KEY,
		webEnv.ADMIN_KEY,
		repoEnv.ADMIN_KEY,
		processEnv.ADMIN_KEY,
		DEFAULT_PLAYWRIGHT_ADMIN_KEY
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
		DEFAULT_E2E_USER_EMAIL
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
		DEFAULT_E2E_USER_PASSWORD
	);
	assignFirstDefinedEnvValue(
		processEnv,
		'DATABASE_URL',
		processEnv.DATABASE_URL,
		repoEnv.DATABASE_URL,
		webEnv.DATABASE_URL
	);
}

/**
 * Resolve Playwright runtime configuration from a three-layer env fallback chain
 * (processEnv → repoEnv → webEnv) with loopback-only URL guardrails. Returns the
 * base URL for test navigation and, when no explicit BASE_URL is set, a webServer
 * block that launches the SvelteKit dev server with the merged env (including a
 * shared JWT_SECRET and ADMIN_KEY so cookie auth and admin routes work end-to-end).
 */
export function resolvePlaywrightRuntime({
	processEnv,
	repoEnv,
	webEnv,
	fallbackJwtSecret
}: ResolvePlaywrightRuntimeParams): PlaywrightRuntimeContract {
	const baseURL = requireLoopbackHttpUrl(
		'BASE_URL',
		processEnv.BASE_URL ?? DEFAULT_PLAYWRIGHT_BASE_URL
	);
	const apiBaseUrl = requireLoopbackHttpUrl(
		'API_BASE_URL',
		webEnv.API_BASE_URL ?? repoEnv.API_BASE_URL ?? processEnv.API_BASE_URL ?? DEFAULT_API_URL
	);
	const webServerEnv = sanitizeWebServerEnv({
		...processEnv,
		...repoEnv,
		...webEnv,
		API_BASE_URL: apiBaseUrl,
		JWT_SECRET:
			webEnv.JWT_SECRET ?? repoEnv.JWT_SECRET ?? processEnv.JWT_SECRET ?? fallbackJwtSecret,
		ADMIN_KEY:
			processEnv.E2E_ADMIN_KEY ??
			webEnv.ADMIN_KEY ??
			repoEnv.ADMIN_KEY ??
			processEnv.ADMIN_KEY ??
			DEFAULT_PLAYWRIGHT_ADMIN_KEY
	});

	return {
		baseURL,
		webServerEnv,
		webServer: processEnv.BASE_URL
			? undefined
			: {
					command: PLAYWRIGHT_WEB_SERVER_COMMAND,
					env: webServerEnv,
					url: DEFAULT_PLAYWRIGHT_BASE_URL,
					reuseExistingServer: false,
					timeout: 30_000
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

/** Reject any URL that is not http/https on a loopback host to prevent credentialed requests leaking to non-local endpoints. */
export function requireLoopbackHttpUrl(varName: string, rawUrl: string): string {
	let parsed: URL;
	try {
		parsed = new URL(rawUrl);
	} catch {
		throw new Error(
			`${varName} must be a valid http:// or https:// loopback URL for credentialed local browser runs`
		);
	}

	if (!['http:', 'https:'].includes(parsed.protocol) || !LOOPBACK_HOSTS.has(parsed.hostname)) {
		throw new Error(
			`${varName} must use a local loopback host (localhost, 127.0.0.1, or [::1]) for credentialed local browser runs`
		);
	}

	return rawUrl;
}

export function resolveFixtureEnv(processEnv: Record<string, string | undefined>): FixtureEnv {
	return {
		apiUrl: requireLoopbackHttpUrl('API_URL', processEnv.API_URL ?? DEFAULT_API_URL),
		adminKey: processEnv.E2E_ADMIN_KEY ?? processEnv.ADMIN_KEY,
		userEmail: processEnv.E2E_USER_EMAIL,
		userPassword: processEnv.E2E_USER_PASSWORD,
		testRegion: processEnv.E2E_TEST_REGION ?? DEFAULT_TEST_REGION,
		flapjackUrl: requireLoopbackHttpUrl(
			'FLAPJACK_URL',
			processEnv.FLAPJACK_URL ?? DEFAULT_FLAPJACK_URL
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
