import { randomUUID } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { requireNonBlankString, requireNonEmptyString } from './tests/fixtures/contract-guards';

export const DEFAULT_PLAYWRIGHT_BASE_URL = 'http://localhost:5173';
export const DEFAULT_PLAYWRIGHT_ADMIN_KEY = `playwright-local-admin-${randomUUID()}`;
export const PLAYWRIGHT_WEB_SERVER_COMMAND =
	'../scripts/playwright_local_stack.sh --host 127.0.0.1 --port 5173 --strictPort';
export const PLAYWRIGHT_STORAGE_STATE = {
	user: 'tests/fixtures/.auth/user.json',
	onboarding: 'tests/fixtures/.auth/onboarding.json',
	customerJourneys: 'tests/fixtures/.auth/customer-journeys.json',
	admin: 'tests/fixtures/.auth/admin.json'
} as const;
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
		name: 'chromium:signup',
		testMatch: /e2e-ui\/full\/signup_to_paid_invoice\.spec\.ts/,
		use: { desktopBrowser: 'chromium' }
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
	fallbackJwtSecret
}: ResolvePlaywrightRuntimeParams): PlaywrightRuntimeContract {
	// Thread processEnv through so the LB-2/LB-3 remote-target opt-in
	// (PLAYWRIGHT_TARGET_REMOTE=1) is observed deterministically by the
	// loopback guard during runtime resolution.
	const baseURL = requireLoopbackHttpUrl(
		'BASE_URL',
		processEnv.BASE_URL ?? DEFAULT_PLAYWRIGHT_BASE_URL,
		processEnv
	);
	const apiBaseUrl = requireLoopbackHttpUrl(
		'API_BASE_URL',
		processEnv.API_BASE_URL ?? repoEnv.API_BASE_URL ?? webEnv.API_BASE_URL ?? DEFAULT_API_URL,
		processEnv
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
			DEFAULT_PLAYWRIGHT_ADMIN_KEY,
		// The Apr27 hardening (commit d4dde081 "Harden signup verification
		// bypass") gated SKIP_EMAIL_VERIFICATION on ENVIRONMENT ∈
		// {local,dev,development}. Both must be set together for the spawned
		// API server to auto-verify signups, otherwise /signup → /dashboard
		// redirects back to /login because verification is required, breaking
		// every fixture in tests/fixtures/onboarding-auth-shared.ts and
		// auth.setup.ts. These ONLY apply to the locally-spawned webServer
		// (this whole block is skipped when processEnv.BASE_URL is set, e.g.
		// running playwright against a real remote deploy).
		ENVIRONMENT: 'local',
		SKIP_EMAIL_VERIFICATION: '1'
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
