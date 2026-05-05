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
import { findVerificationTokenViaStagingSsm } from './staging_db_lookup';
import {
	REMOTE_TARGET_OPT_IN_ENV,
	requireLoopbackHttpUrl,
	resolveFixtureEnv,
	resolveRequiredFixtureUserCredentials
} from '../../playwright.config.contract';
import { requireAdminApiKey, requireNonEmptyString } from './contract-guards';
import type { EstimatedBillResponse } from '../../src/lib/api/types';
import type { AdminRateCard } from '../../src/lib/admin-client';
import {
	pricingContractSnapshotFromAdminRateCard,
	type MarketingPricingContractSnapshot
} from '../../src/lib/pricing';

// ---------------------------------------------------------------------------
// Internal HTTP helpers — never imported by spec files
// ---------------------------------------------------------------------------

// Single env resolution — all fixture consumers read from this instead of
// independently resolving process.env with their own defaults.
const fixtureEnv = resolveFixtureEnv(process.env);

let _token: string | null = null;
let _customerId: string | null = null;
let _staleFixtureIndexesCleaned = false;

const STALE_FIXTURE_INDEX_PREFIXES = ['e2e-', 'manual-iso-', 'test-index'] as const;

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
};

type TrackCustomerForCleanupFn = (customerId: string) => void;

const JSON_CONTENT_TYPE = { 'Content-Type': 'application/json' } as const;
export const FIXTURE_BOOTSTRAP_REMEDIATION_COMMAND = 'scripts/bootstrap-env-local.sh';

type FixtureSetupFailureParams = {
	setupName: string;
	expectedPath: string;
	currentPath: string;
	apiUrl: string;
	adminKey?: string;
	alertText?: string | null;
	responseStatus?: number;
	responseUrl?: string;
	bootstrapCommand?: string;
};

const FRESH_SIGNUP_ARRANGE_SETUP_FAILURE_ALERT_PATTERN = /service is unavailable|verify API_URL/i;
const VERIFY_EMAIL_TOKEN_PATH_PATTERN = /\/verify-email\/[A-Za-z0-9_-]+/g;
const SENSITIVE_QUERY_PARAM_PATTERN =
	/([?&](?:token|verification_token|verificationToken|secret|key|code)=)[^&#\s]*/gi;
const BEARER_TOKEN_PATTERN = /\bBearer\s+[A-Za-z0-9._~+/=-]+\b/g;

function formatAdminKeyFingerprint(adminKey?: string): string {
	if (!adminKey?.trim()) {
		return '(missing)';
	}

	const normalizedAdminKey = adminKey.trim();
	return `(present, len=${normalizedAdminKey.length})`;
}

function redactSensitiveDiagnostics(value: string): string {
	return value
		.replace(VERIFY_EMAIL_TOKEN_PATH_PATTERN, '/verify-email/[REDACTED]')
		.replace(SENSITIVE_QUERY_PARAM_PATTERN, '$1[REDACTED]')
		.replace(BEARER_TOKEN_PATTERN, 'Bearer [REDACTED]');
}

function formatResponseDiagnostic(responseStatus?: number, responseUrl?: string): string {
	if (responseStatus !== undefined && responseUrl) {
		return `status ${responseStatus} at ${redactSensitiveDiagnostics(responseUrl)}`;
	}
	if (responseStatus !== undefined) {
		return `status ${responseStatus}`;
	}
	if (responseUrl) {
		return `URL ${redactSensitiveDiagnostics(responseUrl)}`;
	}
	return '(none observed)';
}

/** Build a non-secret setup failure message for browser auth fixtures. */
export function formatFixtureSetupFailure({
	setupName,
	expectedPath,
	currentPath,
	apiUrl,
	adminKey,
	alertText,
	responseStatus,
	responseUrl,
	bootstrapCommand = FIXTURE_BOOTSTRAP_REMEDIATION_COMMAND
}: FixtureSetupFailureParams): string {
	const normalizedAlertText = redactSensitiveDiagnostics(alertText?.trim() || '(none)');
	const remediationMessage =
		`Run ${bootstrapCommand} to bootstrap .env.local, then start the local stack with scripts/local-dev-up.sh and the Rust API with scripts/api-dev.sh. ` +
		'If you override BASE_URL, start the web frontend with scripts/web-dev.sh too. See docs/runbooks/local-dev.md for setup instructions.';

	return [
		`${setupName} failed before reaching ${expectedPath}. Current URL: ${redactSensitiveDiagnostics(currentPath)}`,
		`API URL: ${apiUrl}`,
		`Admin key fingerprint: ${formatAdminKeyFingerprint(adminKey)}`,
		`Visible alert text: ${normalizedAlertText}`,
		`Login response: ${formatResponseDiagnostic(responseStatus, responseUrl)}`,
		`Remediation: ${remediationMessage}`
	].join('\n');
}

type ThrowFreshSignupArrangeFailureParams = {
	currentPath: string;
	alertText?: string | null;
	responseStatus?: number;
	responseUrl?: string;
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
	throw new Error(
		formatFixtureSetupFailure({
			setupName: 'fresh-signup arrange',
			expectedPath: '/dashboard',
			currentPath,
			apiUrl: fixtureEnv.apiUrl,
			adminKey: fixtureEnv.adminKey,
			alertText,
			responseStatus,
			responseUrl
		})
	);
}

/** Throws a fixture-owned fail-closed setup error for billing-portal prerequisites. */
function throwBillingPortalArrangeFailure({
	currentPath,
	error,
	responseStatus,
	responseUrl
}: ThrowBillingPortalArrangeFailureParams): never {
	throw new Error(
		formatFixtureSetupFailure({
			setupName: 'billing-portal arrange',
			expectedPath: '/dashboard/billing',
			currentPath,
			apiUrl: fixtureEnv.apiUrl,
			adminKey: fixtureEnv.adminKey,
			alertText: setupFailureDetailsFromError(error),
			responseStatus,
			responseUrl
		})
	);
}

function setupFailureDetailsFromError(error: unknown): string {
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

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

function getTransientRetryDelayMs(attempt: number): number {
	return Math.min(2000 * (attempt + 1), 10_000);
}

function getRetryDelayMs(attempt: number, retryAfterHeader: string | null): number {
	const retryAfterSeconds = Number(retryAfterHeader ?? '');
	const retryAfterMs =
		Number.isFinite(retryAfterSeconds) && retryAfterSeconds > 0 ? retryAfterSeconds * 1000 : 0;
	return Math.max(retryAfterMs, getTransientRetryDelayMs(attempt));
}

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

	const maxRetries = 10;
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
			const retryAfterSeconds = Number(res.headers.get('retry-after') ?? '');
			const retryAfterMs =
				Number.isFinite(retryAfterSeconds) && retryAfterSeconds > 0 ? retryAfterSeconds * 1000 : 0;
			await sleep(Math.max(retryAfterMs, getTransientRetryDelayMs(attempt)));
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
	const maxRetries = 10;
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
			const retryAfterSeconds = Number(res.headers.get('retry-after') ?? '');
			const retryAfterMs =
				Number.isFinite(retryAfterSeconds) && retryAfterSeconds > 0 ? retryAfterSeconds * 1000 : 0;
			await sleep(Math.max(retryAfterMs, getTransientRetryDelayMs(attempt)));
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

/** Fetch the authenticated customer's estimated bill, returning null on 404. */
export async function fetchEstimatedBillForToken({
	apiUrl,
	token,
	month,
	fetchImpl = fetch
}: FetchEstimatedBillForTokenParams): Promise<EstimatedBillResponse | null> {
	const localApiUrl = requireLoopbackHttpUrl('API_URL', apiUrl);
	const query = month ? `?month=${encodeURIComponent(month)}` : '';
	const res = await fetchImpl(`${localApiUrl}/billing/estimate${query}`, {
		method: 'GET',
		headers: {
			Authorization: `Bearer ${token}`
		}
	});
	if (!res.ok) {
		// 404 means no estimate data exists yet — genuine absence
		if (res.status === 404) {
			return null;
		}
		// Auth failures (401/403) and server errors (5xx) must surface immediately
		throw new Error(`/billing/estimate failed: ${res.status} ${await res.text()}`);
	}
	return (await res.json()) as EstimatedBillResponse;
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
	for (let attempt = 0; attempt < maxRetries; attempt++) {
		const res = await callJsonApi(
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

	throw new Error('Auth login failed: exhausted retries after 429 rate limiting');
}

async function getCustomerId(): Promise<string> {
	if (_customerId) return _customerId;
	const token = await getAuthToken();
	const maxRetries = 6;
	for (let attempt = 0; attempt < maxRetries; attempt++) {
		const res = await fetch(`${fixtureEnv.apiUrl}/account`, {
			headers: { Authorization: `Bearer ${token}` }
		});
		if (res.status === 429) {
			await sleep(getTransientRetryDelayMs(attempt));
			continue;
		}
		if (!res.ok) {
			throw new Error(`GET /account failed: ${res.status} ${await res.text()}`);
		}
		const data = (await res.json()) as { id: string };
		_customerId = data.id;
		return _customerId;
	}
	throw new Error('GET /account failed: exhausted retries after 429 rate limiting');
}

async function apiCall(
	method: string,
	path: string,
	body?: unknown,
	tokenOverride?: string
): Promise<Response> {
	const token = tokenOverride ?? (await getAuthToken());
	return callJsonApi(
		fetch,
		fixtureEnv.apiUrl,
		method,
		path,
		{ Authorization: `Bearer ${token}` },
		body
	);
}

async function adminApiCall(method: string, path: string, body?: unknown): Promise<Response> {
	let lastResponse: Response | null = null;

	for (let attempt = 0; attempt < 10; attempt += 1) {
		const response = await callJsonApi(
			fetch,
			fixtureEnv.apiUrl,
			method,
			path,
			{ 'x-admin-key': requireAdminApiKey(fixtureEnv.adminKey) },
			body
		);

		if (response.status !== 429) {
			return response;
		}

		lastResponse = response;
		if (attempt === 9) {
			break;
		}

		await sleep(getRetryDelayMs(attempt, response.headers.get('retry-after')));
	}

	return lastResponse ?? new Response('adminApiCall exhausted without a response', { status: 500 });
}

async function bestEffortAdminApiCall(
	method: string,
	path: string,
	body?: unknown
): Promise<Response | null> {
	try {
		return await callJsonApi(
			fetch,
			fixtureEnv.apiUrl,
			method,
			path,
			{ 'x-admin-key': requireAdminApiKey(fixtureEnv.adminKey) },
			body
		);
	} catch {
		return null;
	}
}

function isStaleFixtureIndexName(name: string): boolean {
	return STALE_FIXTURE_INDEX_PREFIXES.some((prefix) => name.startsWith(prefix));
}

async function cleanupStaleFixtureIndexesOnce(): Promise<void> {
	if (_staleFixtureIndexesCleaned) {
		return;
	}

	let res: Response | null = null;
	for (let attempt = 0; attempt < 10; attempt += 1) {
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
		_staleFixtureIndexesCleaned = true;
		return;
	}

	const indexes = (await res.json()) as Array<{ name: string }>;
	const staleNames = indexes
		.map((index) => index.name.trim())
		.filter((name) => name && isStaleFixtureIndexName(name));

	for (const name of staleNames) {
		await apiCall('DELETE', `/indexes/${encodeURIComponent(name)}`, { confirm: true }).catch(() => {
			/* ignore teardown races */
		});
	}

	if (staleNames.length > 0 && fixtureEnv.adminKey) {
		const customerId = await getCustomerId();
		await adminApiCall('PUT', `/admin/tenants/${encodeURIComponent(customerId)}/quotas`, {
			max_indexes: 100
		}).catch(() => {
			/* ignore quota uplift failures; cleanup already made a best effort */
		});
	}

	_staleFixtureIndexesCleaned = true;
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
	flapjackUrl: string
): Promise<void> {
	const safeFlapjackUrl = requireLoopbackHttpUrl('FLAPJACK_URL', flapjackUrl);
	const maxRetries = 6;
	let lastFailure = 'none';

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

		if (res.status !== 429 && res.status !== 500) {
			throw new Error(`seedIndex failed: ${lastFailure}`);
		}

		await sleep(getTransientRetryDelayMs(attempt));
	}

	throw new Error(`seedIndex failed after transient create retries: ${lastFailure}`);
}

async function getCurrentBillingPlan(tokenOverride?: string): Promise<'free' | 'shared'> {
	const res = await apiCall('GET', '/account', undefined, tokenOverride);
	if (!res.ok) {
		throw new Error(`GET /account failed: ${res.status} ${await res.text()}`);
	}
	const data = (await res.json()) as { billing_plan: 'free' | 'shared' };
	return data.billing_plan;
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

function currentUtcBillingMonth(now = new Date()): string {
	const month = String(now.getUTCMonth() + 1).padStart(2, '0');
	return `${now.getUTCFullYear()}-${month}`;
}

function getMailpitApiUrl(): string {
	const configuredMailpitApiUrl = process.env.MAILPIT_API_URL?.trim();
	if (!configuredMailpitApiUrl) {
		throw new Error(
			formatFixtureSetupFailure({
				setupName: 'fresh-signup mailpit setup',
				expectedPath: 'MAILPIT_API_URL',
				currentPath: '(env:MAILPIT_API_URL)',
				apiUrl: fixtureEnv.apiUrl,
				adminKey: fixtureEnv.adminKey,
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

	throw new Error(
		formatFixtureSetupFailure({
			setupName: 'fresh-signup email verification token lookup',
			expectedPath: '/verify-email/{token}',
			currentPath: '(mailpit search)',
			apiUrl: fixtureEnv.apiUrl,
			adminKey: fixtureEnv.adminKey,
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
		// Public auth pages redirect authenticated users to /dashboard, so clear
		// auth cookies before exercising the verify-email success contract.
		await page.context().clearCookies();
		await page.goto(`/verify-email/${verificationToken}`);
		await expect(page.getByRole('heading', { name: 'Email Verified' })).toBeVisible({
			timeout: 30_000
		});
		return { verificationToken };
	} catch (error) {
		throw new Error(
			formatFixtureSetupFailure({
				setupName: 'fresh-signup email verification replay setup',
				expectedPath: '/verify-email/{token}',
				currentPath: page.url() || '(no browser url)',
				apiUrl: fixtureEnv.apiUrl,
				adminKey: fixtureEnv.adminKey,
				alertText: setupFailureDetailsFromError(error)
			})
		);
	}
}

async function getCustomerIdForToken(token: string): Promise<string> {
	const accountResponse = await callJsonApi(fetch, fixtureEnv.apiUrl, 'GET', '/account', {
		Authorization: `Bearer ${token}`
	});
	if (!accountResponse.ok) {
		throw new Error(
			`getCustomerIdForToken failed: ${accountResponse.status} ${await accountResponse.text()}`
		);
	}

	const accountPayload = (await accountResponse.json()) as { id?: string };
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
				nonDefaultPaymentMethodId: 'pm_local_secondary'
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

		return {
			...created,
			token,
			stripeCustomerId,
			defaultPaymentMethodId,
			nonDefaultPaymentMethodId
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
	billingMonth: string
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
		const monthStart = `${billingMonth}-01`;
		const invoices = await listInvoicesBestEffort(token);
		const existing = invoices.find((invoice) => invoice.period_start === monthStart);
		if (existing) {
			return existing.id;
		}
		throw new Error(
			`arrangePaidInvoiceForFreshSignup reported already_invoiced for ${billingMonth} but no matching invoice was visible`
		);
	}

	throw new Error(
		`arrangePaidInvoiceForFreshSignup unexpected batch status for customer ${customerId}: ${customerResult.status} (${customerResult.reason ?? 'no reason'})`
	);
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

async function waitForInvoiceStatus({
	invoiceId,
	token,
	expectedStatus,
	contextLabel
}: WaitForInvoiceStatusParams): Promise<InvoiceDetailApiItem> {
	const maxAttempts = 30;
	for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
		const response = await apiCall(
			'GET',
			`/invoices/${encodeURIComponent(invoiceId)}`,
			undefined,
			token
		);
		if (response.ok) {
			const invoice = (await response.json()) as InvoiceDetailApiItem;
			if (invoice.status === expectedStatus && (expectedStatus !== 'paid' || invoice.paid_at)) {
				return invoice;
			}
		} else if (response.status !== 404 && response.status !== 429) {
			throw new Error(
				`${contextLabel} failed to read invoice ${invoiceId}: ${response.status} ${await response.text()}`
			);
		}

		await sleep(1000);
	}

	throw new Error(
		`${contextLabel} timed out waiting for invoice ${invoiceId} to become ${expectedStatus}`
	);
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

		const token = await loginAsUser({
			apiUrl: fixtureEnv.apiUrl,
			email: normalizedEmail,
			password
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
		await attachDefaultStripeTestCard(
			stripeCustomerId,
			stripeSecretKey,
			'arrangePaidInvoiceForFreshSignup'
		);

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
		const invoiceId = await resolveInvoiceIdFromBatch(batch, customerId, token, billingMonth);
		await waitForInvoicePaid(invoiceId, token);

		return {
			customerId,
			invoiceId,
			billingMonth
		};
	} catch (error) {
		throw new Error(
			formatFixtureSetupFailure({
				setupName: 'arrangePaidInvoiceForFreshSignup',
				expectedPath: '/dashboard/billing/invoices/{id}',
				currentPath: '(arrangePaidInvoiceForFreshSignup)',
				apiUrl: fixtureEnv.apiUrl,
				adminKey: fixtureEnv.adminKey,
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

// ---------------------------------------------------------------------------
// Custom fixture types
// ---------------------------------------------------------------------------

type SeedIndexFn = (name: string, region?: string) => Promise<void>;
type SeedCustomerIndexFn = (
	customer: CreatedFixtureUser,
	name: string,
	region?: string
) => Promise<void>;
type RegisterIndexForCleanupFn = (name: string) => void;
type CleanupFixtureIndexesFn = () => Promise<void>;
type SeedApiKeyFn = (name: string, scopes?: string[]) => Promise<{ id: string }>;
type SetBillingPlanFn = (plan: 'free' | 'shared') => Promise<void>;
type SeedInvoiceFn = () => Promise<{ id: string }>;
type SeedInvoiceWithPdfUrlFn = () => Promise<{ id: string }>;
type CreateUserFn = (email: string, password: string, name?: string) => Promise<CreatedFixtureUser>;
type LoginAsFn = (email: string, password: string) => Promise<string>;
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
type CompleteFreshSignupEmailVerificationFn = (
	page: Page,
	email: string
) => Promise<{ verificationToken: string }>;
type ArrangePaidInvoiceForFreshSignupFn = (
	email: string,
	password: string
) => Promise<ArrangePaidInvoiceForFreshSignupResult>;
type IsFreshSignupArrangePrerequisiteFailureFn = (alertText: string) => boolean;
type ThrowFreshSignupArrangeFailureFn = (input: {
	currentPath: string;
	alertText?: string | null;
	responseStatus?: number;
	responseUrl?: string;
}) => never;

type E2eFixtures = {
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
	/** Temporarily switch the authenticated customer between free and shared plans. */
	setBillingPlan: SetBillingPlanFn;
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
	/** Resolve a real Mailpit token and complete /verify-email/{token} in the browser. */
	completeFreshSignupEmailVerification: CompleteFreshSignupEmailVerificationFn;
	/** Advance a fresh verified signup through paid billing and invoice-email evidence. */
	arrangePaidInvoiceForFreshSignup: ArrangePaidInvoiceForFreshSignupFn;
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
			await bestEffortAdminApiCall('DELETE', `/admin/tenants/${encodeURIComponent(customerId)}`);
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
			await cleanupStaleFixtureIndexesOnce();
			const r = region ?? fixtureEnv.testRegion;
			// Use the admin endpoint to seed a local Flapjack-backed index directly
			// so tab/detail browser proofs exercise the real local engine.
			const customerId = await getCustomerId();
			await createSeededIndex(customerId, name, r, fixtureEnv.flapjackUrl);
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
			await createSeededIndex(customer.customerId, name, r, fixtureEnv.flapjackUrl);
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
