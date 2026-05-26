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
import { createSeedSearchableIndexFactory, type SeedSearchableIndexFn } from './searchable-index';
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
	requireLoopbackHttpUrl,
	resolveFixtureEnv,
	resolveRequiredFixtureUserCredentials
} from '../../playwright.config.contract';
import { AUTH_COOKIE } from '../../src/lib/server/auth-session-contracts';
import { requireAdminApiKey, requireNonEmptyString } from './contract-guards';
import { attemptRemoteSignupFallback, isRemoteTargetMode } from './fresh_signup_remote_bootstrap';
import type {
	ApiKeyListItem,
	EstimatedBillResponse,
	Rule,
	RuleSearchResponse
} from '../../src/lib/api/types';
import type { AdminRateCard } from '../../src/lib/admin-client';
import {
	pricingContractSnapshotFromAdminRateCard,
	type MarketingPricingContractSnapshot
} from '../../src/lib/pricing';
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

const STALE_FIXTURE_INDEX_PREFIXES = ['e2e-', 'manual-iso-', 'test-index'] as const;

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

async function getAccountPayloadForTokenWithRetries(
	token: string,
	contextLabel: string
): Promise<{ id?: string; billing_plan?: 'free' | 'shared' }> {
	const maxRetries = TRANSIENT_API_MAX_RETRIES;
	let lastTransientFailure = 'none';
	let currentToken = token;
	let refreshedAfterUnauthorized = false;

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

function isStaleFixtureIndexName(name: string): boolean {
	return STALE_FIXTURE_INDEX_PREFIXES.some((prefix) => name.startsWith(prefix));
}

async function cleanupStaleFixtureIndexesOnce(): Promise<void> {
	if (_staleFixtureIndexesCleaned) {
		return;
	}
	if (Date.now() < _staleFixtureIndexesCleanupCooldownUntil) {
		return;
	}

	let res: Response | null = null;
	for (let attempt = 0; attempt < 4; attempt += 1) {
		res = await apiCall('GET', '/indexes');
		if (res.ok) {
			break;
		}
		if (res.status !== 429) {
			throw new Error(
				`cleanupFixtureIndexes failed to list indexes: ${res.status} ${await res.text()}`
			);
		}
		await sleep(getRetryDelayMs(attempt, res.headers.get('retry-after')));
	}
	if (!res?.ok) {
		// This cleanup only removes stale local fixtures. If the shared test user is
		// currently throttled, failing the spec here is noisier than tolerating a
		// best-effort miss and letting the real test assertions speak for themselves.
		//
		// Do not mark cleanup as complete when list reads never succeeded: a later
		// fixture call in this worker should retry once throttling clears.
		_staleFixtureIndexesCleanupCooldownUntil = Date.now() + 30_000;
		return;
	}

	const indexes = (await res.json()) as Array<{ name: string }>;
	const staleNames = indexes
		.map((index) => index.name.trim())
		.filter((name) => name && isStaleFixtureIndexName(name));

	// Shared-host runs can accumulate a very large stale e2e index set.
	// Use a wider one-time cleanup window so quota and rate-limit pressure
	// drops before the suite starts creating fresh indexes.
	const cleanupDeadline = Date.now() + 30_000;
	const unresolvedStaleDeletes: string[] = [];
	for (let staleNameIndex = 0; staleNameIndex < staleNames.length; staleNameIndex += 1) {
		const name = staleNames[staleNameIndex];
		if (Date.now() > cleanupDeadline) {
			unresolvedStaleDeletes.push(...staleNames.slice(staleNameIndex));
			break;
		}
		let deleted = false;
		for (let attempt = 0; attempt < 10; attempt += 1) {
			if (Date.now() > cleanupDeadline) {
				break;
			}
			const deleteRes = await apiCall('DELETE', `/indexes/${encodeURIComponent(name)}`, {
				confirm: true
			}).catch(() => null);
			if (!deleteRes) {
				await sleep(getTransientRetryDelayMs(attempt));
				continue;
			}
			if (deleteRes.ok || deleteRes.status === 404) {
				deleted = true;
				break;
			}
			if (deleteRes.status !== 429 && deleteRes.status !== 500 && deleteRes.status !== 503) {
				break;
			}
			await sleep(getRetryDelayMs(attempt, deleteRes.headers.get('retry-after')));
		}
		if (!deleted) {
			unresolvedStaleDeletes.push(name);
		}
	}

	// Cleanup stays retryable across fixture calls until stale rows converge.
	if (unresolvedStaleDeletes.length > 0) {
		_staleFixtureIndexesCleanupCooldownUntil = Date.now() + 30_000;
		return;
	}

	_staleFixtureIndexesCleaned = true;
	_staleFixtureIndexesCleanupCooldownUntil = 0;
}

async function waitForSeededIndex(name: string): Promise<void> {
	const maxAttempts = 60;
	const pollIntervalMs = 500;
	let lastStatus: number | null = null;

	for (let attempt = 0; attempt < maxAttempts; attempt++) {
		const res = await apiCall('GET', `/indexes/${encodeURIComponent(name)}`);
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

async function createSeededIndex(
	customerId: string,
	name: string,
	region: string,
	flapjackUrl: string,
	customerToken?: string
): Promise<void> {
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
		// admin key mid-suite. Recover by creating through the authenticated
		// customer route when admin auth is rejected.
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
			if (
				fallbackResponse.status === 400 &&
				fallbackBody.toLowerCase().includes('index limit reached')
			) {
				await cleanupStaleFixtureIndexesOnce();
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
		} else if (res.status !== 401 && res.status !== 429 && res.status !== 500) {
			throw new Error(`seedIndex failed: ${lastFailure}`);
		}

		await sleep(getTransientRetryDelayMs(attempt));
	}

	throw new Error(`seedIndex failed after transient create retries: ${lastFailure}`);
}

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

function buildFreshSignupIdentity(seed?: string): FreshSignupIdentity {
	const identitySeed = seed?.trim() || `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
	return {
		name: `Signup Lane ${identitySeed}`,
		email: `signup-paid-${identitySeed}@e2e.griddle.test`,
		password: 'TestPassword123!'
	};
}

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

async function findVerificationTokenViaMailpit(email: string): Promise<string> {
	const normalizedEmail = requireNonEmptyString(
		email,
		'findVerificationTokenViaMailpit requires a non-empty email'
	);
	const maxAttempts = 30;
	const query = `to:${normalizedEmail}`;

	for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
		const messageIds = await fetchMailpitMessageIds(query).catch(() => []);
		for (const messageId of messageIds) {
			const payload = await fetchMailpitMessagePayload(messageId).catch(() => null);
			const token = extractVerificationTokenFromMailpitPayload(payload);
			if (token) {
				return token;
			}
		}

		await sleep(1000);
	}

	const diagnosticEnv = fixtureEnvForFailureDiagnostics();
	throw new Error(
		formatFixtureSetupFailure({
			setupName: 'fresh-signup email verification token lookup',
			expectedPath: '/verify-email/{token}',
			currentPath: '(mailpit search)',
			apiUrl: diagnosticEnv.apiUrl,
			adminKey: diagnosticEnv.adminKey,
			alertText: `No verification token found in Mailpit for ${normalizedEmail} after ${maxAttempts}s`
		})
	);
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

async function completeFreshSignupEmailVerificationViaRoute(
	page: Page,
	email: string
): Promise<{ verificationToken: string }> {
	try {
		const verificationToken = await findFreshSignupVerificationToken(email);
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

async function getCustomerIdForToken(token: string): Promise<string> {
	const accountPayload = await getAccountPayloadForTokenWithRetries(token, 'getCustomerIdForToken');
	return requireNonEmptyString(
		accountPayload.id ?? '',
		'getCustomerIdForToken received an empty customer id'
	);
}

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
		const verificationToken = await findFreshSignupVerificationToken(email);
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

async function payStripeInvoiceWithTestKey(
	stripeInvoiceId: string,
	stripeSecretKey: string,
	contextLabel: string
): Promise<void> {
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

type SeedIndexFn = (name: string, region?: string) => Promise<void>;
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
	region?: string
) => Promise<void>;
type RegisterIndexForCleanupFn = (name: string) => void;
type CleanupFixtureIndexesFn = () => Promise<void>;
type SeedApiKeyFn = (name: string, scopes?: string[]) => Promise<{ id: string }>;
type SeedRulePayload = { objectID: string } & Record<string, unknown>;
type SeedRulesFn = (indexName: string, rules: SeedRulePayload[]) => Promise<void>;
type GetRuleFn = (indexName: string, objectID: string) => Promise<Rule>;
type SearchRulesFn = (
	indexName: string,
	query?: string,
	page?: number,
	hitsPerPage?: number
) => Promise<RuleSearchResponse>;
type ReadClipboardTextFn = (page: Page) => Promise<string>;
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
type SeedInvoiceFn = () => Promise<{ id: string }>;
type SeedInvoiceWithPdfUrlFn = () => Promise<{ id: string }>;
type CreateUserFn = (email: string, password: string, name?: string) => Promise<CreatedFixtureUser>;
export type LoginAsFn = (email: string, password: string) => Promise<string>;
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
type GetDisposableTenantRateCardSnapshotFn = () => Promise<MarketingPricingContractSnapshot>;
type ArrangeBillingPortalCustomerFn = () => Promise<ArrangeBillingPortalCustomerResult>;
type CreateFreshSignupIdentityFn = () => FreshSignupIdentity;
type FindCustomerStatusViaStagingSsmFn = (email: string) => Promise<StagingCustomerStatusEvidence>;
type FindPaidInvoiceEvidenceViaStagingSsmFn = (
	invoiceId: string
) => Promise<StagingPaidInvoiceEvidence>;
type CompleteFreshSignupEmailVerificationFn = (
	page: Page,
	email: string
) => Promise<{ verificationToken: string }>;
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

type E2eFixtures = {
	/** Resolved API origin from resolveFixtureEnv (single env-contract owner). */
	apiUrl: string;
	/** Seed an index via the admin API and auto-delete after the test. */
	seedIndex: SeedIndexFn;
	/** Seed an index for a newly-created customer fixture without switching browser auth state. */
	seedCustomerIndex: SeedCustomerIndexFn;
	/** Register an index name for teardown when the index is created via UI flow. */
	registerIndexForCleanup: RegisterIndexForCleanupFn;
	/** Remove leaked safe-to-delete test indexes from prior runs for the shared fixture user. */
	cleanupFixtureIndexes: CleanupFixtureIndexesFn;
	/** Seed an API key and auto-revoke after the test. */
	seedApiKey: SeedApiKeyFn;
	/** Seed one or more rules and auto-delete them after the test. */
	seedRules: SeedRulesFn;
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
		const created = new Set<string>();
		await use((name: string) => {
			const trimmed = name.trim();
			if (!trimmed) return;
			created.add(trimmed);
		});

		for (const name of created) {
			await apiCall('DELETE', `/indexes/${encodeURIComponent(name)}`, { confirm: true }).catch(
				() => {
					/* ignore — may already be gone */
				}
			);
		}
	},

	_trackCustomerForCleanup: async ({}, use) => {
		const created = new Set<string>();
		await use((customerId: string) => {
			const trimmed = customerId.trim();
			if (!trimmed) return;
			created.add(trimmed);
		});

		for (const customerId of created) {
			await deleteTrackedCustomerForCleanup(customerId);
		}
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
		await use((page, email) => completeFreshSignupEmailVerificationViaRoute(page, email));
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

	registerIndexForCleanup: async ({ _trackIndexForCleanup }, use) => {
		await use((name: string) => _trackIndexForCleanup(name));
	},

	cleanupFixtureIndexes: async ({}, use) => {
		await use(() => cleanupStaleFixtureIndexesOnce());
	},

	seedIndex: async ({ _trackIndexForCleanup }, use) => {
		const factory: SeedIndexFn = async (name, region) => {
			const r = region ?? fixtureEnv.testRegion;
			// Use the admin endpoint to seed a local Flapjack-backed index directly
			// so tab/detail browser proofs exercise the real local engine.
			const token = await getAuthToken();
			const customerId = await getCustomerId();
			await createSeededIndex(customerId, name, r, fixtureEnv.flapjackUrl, token);
			// The admin create endpoint can return before the customer index-read
			// path is consistent enough for the detail page loader. Poll the same
			// read path the UI uses so seeded detail specs do not flake on a 500.
			await waitForSeededIndex(name);
			_trackIndexForCleanup(name);
		};

		await use(factory);
	},

	seedCustomerIndex: async ({}, use) => {
		const created: Array<{ token: string; name: string }> = [];

		const factory: SeedCustomerIndexFn = async (customer, name, region) => {
			const r = region ?? fixtureEnv.testRegion;
			// Admin seeding lets admin browser specs arrange quota/index state for
			// disposable customers without logging the browser out of admin mode.
			await createSeededIndex(customer.customerId, name, r, fixtureEnv.flapjackUrl, customer.token);
			created.push({ token: customer.token, name });
		};

		await use(factory);

		for (const index of created) {
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
				await seedSearchableIndex(name);
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
			const result = await seedSearchableIndex(name);
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
