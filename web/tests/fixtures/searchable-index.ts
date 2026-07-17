/**
 * Searchable index seeding — provisions Flapjack-backed indexes for E2E tests.
 *
 * Admin-side index creation uses the API admin endpoint. Document ingestion
 * goes directly to the Flapjack engine using a generated scoped API key and
 * the same batch write contract Flapjack currently protects with `addObject`.
 */
import { DEFAULT_FLAPJACK_URL, requireLoopbackHttpUrl } from '../../playwright.config.contract';
import { requireAdminApiKey, requireNonEmptyString } from './contract-guards';
import { buildTenantScopedIndexUid } from '../../src/lib/flapjack-index';

type ApiCallFn = (method: string, path: string, body?: unknown) => Promise<Response>;
type AdminApiCallFn = (method: string, path: string, body?: unknown) => Promise<Response>;
type GetCustomerIdFn = () => Promise<string>;
type WaitForSeededIndexFn = (name: string) => Promise<void>;
type FetchImplFn = typeof fetch;
type SearchHitsResponse = { hits?: Array<{ title?: string }> };
type MetricsResponse = { documents_count?: unknown };
type JsonHeaders = Record<string, string>;

type SearchableIndexMetricsResult = {
	documentsCount: number;
	expectedDocumentCount: number;
};

export type SearchableIndexResult = {
	name: string;
	query: string;
	expectedHitText: string;
	metrics?: SearchableIndexMetricsResult;
};

export type MetricsReadySearchableIndexResult = SearchableIndexResult & {
	metrics: SearchableIndexMetricsResult;
};

export type SearchableIndexMetricsReadyOptions = {
	expectedDocumentCount?: number;
	maxAttempts?: number;
	pollIntervalMs?: number;
};

export type SearchableIndexSeedOptions = {
	query?: string;
	expectedHitText?: string;
	documents?: Array<Record<string, unknown>>;
	metricsReady?: SearchableIndexMetricsReadyOptions;
};

export type SeedSearchableIndexFn = (
	name: string,
	options?: SearchableIndexSeedOptions
) => Promise<SearchableIndexResult>;

export type SeedMetricsSearchableIndexFn = (
	name: string
) => Promise<MetricsReadySearchableIndexResult>;

type SeedIndexForCustomerViaAdminParams = {
	apiUrl: string;
	adminKey?: string;
	customerId: string;
	token: string;
	name: string;
	region: string;
	flapjackUrl?: string;
	fetchImpl?: FetchImplFn;
};

type SeedSearchableIndexForCustomerParams = SeedIndexForCustomerViaAdminParams & {
	query?: string;
	expectedHitText?: string;
	documents?: Array<Record<string, unknown>>;
	metricsReady?: SearchableIndexMetricsReadyOptions;
};

type CreateIndexForCustomerParams = Omit<
	SeedIndexForCustomerViaAdminParams,
	'token' | 'adminKey'
> & {
	adminKey: string;
};

type CreateIndexForCustomerViaTokenParams = Pick<
	SeedIndexForCustomerViaAdminParams,
	'apiUrl' | 'token' | 'name' | 'region' | 'fetchImpl'
>;

type SearchableIndexFactoryDeps = {
	testRegion: string;
	apiCall: ApiCallFn;
	adminApiCall: AdminApiCallFn;
	getCustomerId: GetCustomerIdFn;
	waitForSeededIndex: WaitForSeededIndexFn;
	/** Optional flapjack URL override for admin index creation. Defaults to contract DEFAULT_FLAPJACK_URL. */
	flapjackUrl?: string;
};
type PrimaryDocumentIngestPath = 'direct-flapjack' | 'api-batch';

const DEFAULT_DOCUMENTS: Array<Record<string, unknown>> = [
	{
		objectID: 'doc-1',
		id: 'doc-1',
		title: 'Rust Programming Language',
		body: 'Systems programming',
		category: 'language'
	},
	{
		objectID: 'doc-2',
		id: 'doc-2',
		title: 'TypeScript Handbook',
		body: 'JavaScript with types',
		category: 'tech'
	},
	{
		objectID: 'doc-3',
		id: 'doc-3',
		title: 'Rust Async Book',
		body: 'Futures and async/await in Rust',
		category: 'systems'
	}
];
const DEFAULT_SEARCH_QUERY = 'Rust';
const DEFAULT_EXPECTED_HIT_TEXT = 'Rust Programming Language';
const JSON_CONTENT_TYPE = { 'Content-Type': 'application/json' } as const;
const INDEX_CREATE_MAX_RETRIES = 20;
const INDEX_KEY_CREATE_MAX_RETRIES = 30;
const API_BATCH_INGEST_MAX_RETRIES = 300;
const API_BATCH_ENDPOINT_NOT_READY_RETRY_DELAY_MS = 500;
const METRICS_READY_MAX_ATTEMPTS = 130;
const METRICS_READY_POLL_INTERVAL_MS = 1000;
const METRICS_READY_DOCUMENTS: Array<Record<string, unknown>> = Array.from(
	{ length: 12 },
	(_, index) => ({
		objectID: `metrics-ready-doc-${index + 1}`,
		id: `metrics-ready-doc-${index + 1}`,
		title:
			index === 0
				? 'Metrics Ready Searchable Document'
				: `Metrics Ready Searchable Document ${index + 1}`,
		body: `Metrics readiness fixture document ${index + 1}`,
		category: 'metrics-ready'
	})
);
const METRICS_READY_SEARCH_QUERY = 'Metrics Ready';
const METRICS_READY_EXPECTED_HIT_TEXT = 'Metrics Ready Searchable Document';

// A Flapjack engine URL is only safe to forward as the per-tenant `flapjack_url`
// and to use for direct `/1/indexes/.../batch` ingestion when it points at a
// real Flapjack engine on the local loopback. Remote-target Playwright runs
// hydrate `FLAPJACK_URL` from staging and historically defaulted it to the
// public API origin (e.g. https://api.staging.flapjack.foo); that origin is
// not a Flapjack engine, so passing it through bound the tenant index to a
// non-existent engine and caused `/indexes/{name}/keys` to 404 for the entire
// retry budget. Loopback-only acceptance keeps local runs working while
// forcing remote runs onto the customer API batch path the API already owns.
const LOOPBACK_FLAPJACK_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]']);

function isDirectFlapjackEngineUrl(url: string): boolean {
	try {
		return LOOPBACK_FLAPJACK_HOSTS.has(new URL(url).hostname);
	} catch {
		return false;
	}
}

function resolveSeedFlapjackUrl(rawFlapjackUrl?: string): string | undefined {
	const configuredFlapjackUrl = rawFlapjackUrl?.trim();
	if (configuredFlapjackUrl && configuredFlapjackUrl.length > 0) {
		return requireLoopbackHttpUrl('FLAPJACK_URL', configuredFlapjackUrl);
	}

	// Remote-target runs should treat an omitted FLAPJACK_URL as "no direct
	// engine available" so seeding stays on the customer API path instead of
	// silently reviving the local localhost:7700 default.
	if (process.env.PLAYWRIGHT_TARGET_REMOTE === '1') {
		return undefined;
	}

	return requireLoopbackHttpUrl('FLAPJACK_URL', DEFAULT_FLAPJACK_URL);
}

function buildIndexKeyDescription(name: string): string {
	return `e2e-search-${name}`;
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

async function apiCallWithJsonBody(
	fetchImpl: FetchImplFn,
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

export function createMetricsReadySearchableIndexSeedOptions(): SearchableIndexSeedOptions {
	const documents = METRICS_READY_DOCUMENTS.map((document) => ({ ...document }));
	return {
		query: METRICS_READY_SEARCH_QUERY,
		expectedHitText: METRICS_READY_EXPECTED_HIT_TEXT,
		documents,
		metricsReady: {
			expectedDocumentCount: documents.length
		}
	};
}

function getTransientRetryDelayMs(attempt: number): number {
	return Math.min(2000 * (attempt + 1), 10_000);
}

function responseHasEndpointNotReadyBody(status: number, body: string): boolean {
	return (
		(status === 400 || status === 503) && body.toLowerCase().includes('endpoint not ready yet')
	);
}

function responseRetryAfterMs(response: Response): number {
	const retryAfterSeconds = Number(response.headers.get('retry-after') ?? '');
	return Number.isFinite(retryAfterSeconds) && retryAfterSeconds > 0 ? retryAfterSeconds * 1000 : 0;
}

async function sleepForTransientResponse(response: Response, attempt: number): Promise<void> {
	await sleep(Math.max(responseRetryAfterMs(response), getTransientRetryDelayMs(attempt)));
}

async function sleepForApiBatchIngestRetry(
	response: Response,
	body: string,
	attempt: number
): Promise<void> {
	const retryAfterMs = responseRetryAfterMs(response);
	const retryDelayMs = responseHasEndpointNotReadyBody(response.status, body)
		? API_BATCH_ENDPOINT_NOT_READY_RETRY_DELAY_MS
		: getTransientRetryDelayMs(attempt);
	await sleep(Math.max(retryAfterMs, retryDelayMs));
}

function normalizeSeedIndexAccess(params: {
	adminKey?: string;
	customerId: string;
	token: string;
	name: string;
	errorPrefix: string;
}): { adminKey: string; customerId: string; token: string; name: string } {
	const { adminKey, customerId, token, name, errorPrefix } = params;

	return {
		adminKey: requireAdminApiKey(adminKey),
		token: requireNonEmptyString(token, `${errorPrefix} requires a non-empty token`),
		customerId: requireNonEmptyString(customerId, `${errorPrefix} requires a non-empty customerId`),
		name: requireNonEmptyString(name, `${errorPrefix} requires a non-empty index name`)
	};
}

/** Send an authenticated admin API request for tenant-scoped operations. */
async function adminApiCallForTenant(
	apiUrl: string,
	adminKey: string,
	method: string,
	path: string,
	body?: unknown,
	fetchImpl: FetchImplFn = fetch
): Promise<Response> {
	return apiCallWithJsonBody(fetchImpl, apiUrl, method, path, { 'x-admin-key': adminKey }, body);
}

async function customerApiCallForToken(
	apiUrl: string,
	token: string,
	method: string,
	path: string,
	body?: unknown,
	fetchImpl: FetchImplFn = fetch
): Promise<Response> {
	return apiCallWithJsonBody(
		fetchImpl,
		apiUrl,
		method,
		path,
		{ Authorization: `Bearer ${token}` },
		body
	);
}

/**
 * Normalize fixture documents into Flapjack's batch addObject payload.
 *
 * The live local server gates scoped write keys on the `/batch` route. The
 * older `/documents` shape falls through to an admin-only ACL path there.
 */
function buildAddDocumentsBatch(documents: Array<Record<string, unknown>>): {
	requests: Array<{ action: 'addObject'; body: Record<string, unknown> }>;
} {
	return {
		requests: documents.map((document) => ({
			action: 'addObject',
			body: document
		}))
	};
}

async function ingestDocumentsViaFlapjack({
	flapjackUrl,
	flapjackIndexName,
	key,
	documents,
	fetchImpl = fetch,
	errorPrefix
}: {
	flapjackUrl: string;
	flapjackIndexName: string;
	key: string;
	documents: Array<Record<string, unknown>>;
	fetchImpl?: FetchImplFn;
	errorPrefix: string;
}): Promise<void> {
	const res = await fetchImpl(
		`${flapjackUrl}/1/indexes/${encodeURIComponent(flapjackIndexName)}/batch`,
		{
			method: 'POST',
			headers: {
				'Content-Type': 'application/json',
				'X-Algolia-API-Key': key,
				'X-Algolia-Application-Id': 'flapjack'
			},
			body: JSON.stringify(buildAddDocumentsBatch(documents))
		}
	);
	if (!res.ok) {
		throw new Error(`${errorPrefix}: ingest failed: ${res.status} ${await res.text()}`);
	}
}

async function ingestDocumentsViaApiBatch({
	apiCall,
	indexName,
	documents,
	errorPrefix
}: {
	apiCall: ApiCallFn;
	indexName: string;
	documents: Array<Record<string, unknown>>;
	errorPrefix: string;
}): Promise<void> {
	let lastFailure = 'none';

	for (let attempt = 0; attempt < API_BATCH_INGEST_MAX_RETRIES; attempt++) {
		const response = await apiCall(
			'POST',
			`/indexes/${encodeURIComponent(indexName)}/batch`,
			buildAddDocumentsBatch(documents)
		);

		if (response.ok) {
			return;
		}

		const body = await response.text();
		lastFailure = `${response.status} ${body}`;
		if (
			response.status !== 429 &&
			response.status !== 500 &&
			response.status !== 503 &&
			!responseHasEndpointNotReadyBody(response.status, body)
		) {
			throw new Error(`${errorPrefix}: API batch ingest failed: ${lastFailure}`);
		}

		await sleepForApiBatchIngestRetry(response, body, attempt);
	}

	throw new Error(`${errorPrefix}: API batch ingest failed after retries: ${lastFailure}`);
}

async function waitForExpectedSearchHit({
	apiCall,
	indexName,
	query,
	expectedHitText,
	maxAttempts = 120,
	pollIntervalMs = 500,
	errorPrefix
}: {
	apiCall: ApiCallFn;
	indexName: string;
	query: string;
	expectedHitText: string;
	maxAttempts?: number;
	pollIntervalMs?: number;
	errorPrefix: string;
}): Promise<void> {
	const normalizedExpectedText = expectedHitText.toLowerCase();

	const hasExpectedTextInHit = (hit: Record<string, unknown>): boolean => {
		for (const value of Object.values(hit)) {
			if (typeof value !== 'string') {
				continue;
			}
			if (value.toLowerCase().includes(normalizedExpectedText)) {
				return true;
			}
		}
		return false;
	};

	for (let attempt = 0; attempt < maxAttempts; attempt++) {
		const searchRes = await apiCall('POST', `/indexes/${encodeURIComponent(indexName)}/search`, {
			query
		});
		if (searchRes.ok) {
			const searchData = (await searchRes.json()) as SearchHitsResponse;
			if (searchData.hits?.some((hit) => hasExpectedTextInHit(hit as Record<string, unknown>))) {
				return;
			}
		}
		await sleep(pollIntervalMs);
	}

	throw new Error(`${errorPrefix}: documents not searchable after ${maxAttempts} attempts`);
}

function resolveMetricsReadyOptions(
	metricsReady: SearchableIndexMetricsReadyOptions | undefined,
	documents: Array<Record<string, unknown>>
):
	| {
			expectedDocumentCount: number;
			maxAttempts: number;
			pollIntervalMs: number;
	  }
	| undefined {
	if (!metricsReady) {
		return undefined;
	}

	const expectedDocumentCount = metricsReady.expectedDocumentCount ?? documents.length;
	if (!Number.isInteger(expectedDocumentCount) || expectedDocumentCount < 0) {
		throw new Error('metricsReady.expectedDocumentCount must be a non-negative integer');
	}
	const maxAttempts = metricsReady.maxAttempts ?? METRICS_READY_MAX_ATTEMPTS;
	if (!Number.isInteger(maxAttempts) || maxAttempts <= 0) {
		throw new Error('metricsReady.maxAttempts must be a positive integer');
	}
	const pollIntervalMs = metricsReady.pollIntervalMs ?? METRICS_READY_POLL_INTERVAL_MS;
	if (!Number.isFinite(pollIntervalMs) || pollIntervalMs < 0) {
		throw new Error('metricsReady.pollIntervalMs must be a non-negative number');
	}

	return { expectedDocumentCount, maxAttempts, pollIntervalMs };
}

function readDocumentsCount(metrics: MetricsResponse): number | null {
	return typeof metrics.documents_count === 'number' && Number.isFinite(metrics.documents_count)
		? metrics.documents_count
		: null;
}

async function responseBodyText(response: Response): Promise<string> {
	try {
		return await response.text();
	} catch (error) {
		return `unreadable response body: ${error instanceof Error ? error.message : String(error)}`;
	}
}

async function waitForMetricsReady({
	apiCall,
	indexName,
	expectedDocumentCount,
	maxAttempts,
	pollIntervalMs,
	errorPrefix
}: {
	apiCall: ApiCallFn;
	indexName: string;
	expectedDocumentCount: number;
	maxAttempts: number;
	pollIntervalMs: number;
	errorPrefix: string;
}): Promise<SearchableIndexMetricsResult> {
	let lastObserved = 'no metrics response observed';

	for (let attempt = 0; attempt < maxAttempts; attempt++) {
		const response = await apiCall('GET', `/indexes/${encodeURIComponent(indexName)}/metrics`);
		const body = await responseBodyText(response);
		if (!response.ok) {
			lastObserved = `status=${response.status} body=${body}`;
			await sleep(pollIntervalMs);
			continue;
		}

		let metrics: MetricsResponse;
		try {
			metrics = JSON.parse(body) as MetricsResponse;
		} catch {
			lastObserved = `status=${response.status} body=${body}`;
			await sleep(pollIntervalMs);
			continue;
		}

		const documentsCount = readDocumentsCount(metrics);
		lastObserved =
			documentsCount === null
				? `status=${response.status} body=${body}`
				: `status=${response.status} documents_count=${documentsCount} body=${body}`;
		if (documentsCount === expectedDocumentCount) {
			return {
				documentsCount,
				expectedDocumentCount
			};
		}

		await sleep(pollIntervalMs);
	}

	throw new Error(
		`${errorPrefix}: metrics document count for "${indexName}" did not reach ${expectedDocumentCount} after ${maxAttempts} attempts; last observed ${lastObserved}`
	);
}

async function buildSearchableIndexSeedResult({
	apiCall,
	indexName,
	query,
	expectedHitText,
	metricsReady,
	errorPrefix
}: {
	apiCall: ApiCallFn;
	indexName: string;
	query: string;
	expectedHitText: string;
	metricsReady?: ReturnType<typeof resolveMetricsReadyOptions>;
	errorPrefix: string;
}): Promise<SearchableIndexResult> {
	const result: SearchableIndexResult = {
		name: indexName,
		query,
		expectedHitText
	};
	if (!metricsReady) {
		return result;
	}

	return {
		...result,
		metrics: await waitForMetricsReady({
			apiCall,
			indexName,
			...metricsReady,
			errorPrefix
		})
	};
}

/**
 * Prefer direct Flapjack ingest, then fall back to API batch ingest if search
 * never converges through the primary path.
 */
async function ingestDocumentsWithSearchFallback({
	primaryIngest,
	primaryIngestPath,
	apiCall,
	indexName,
	query,
	expectedHitText,
	documents,
	errorPrefix
}: {
	primaryIngest: () => Promise<void>;
	primaryIngestPath: PrimaryDocumentIngestPath;
	apiCall: ApiCallFn;
	indexName: string;
	query: string;
	expectedHitText: string;
	documents: Array<Record<string, unknown>>;
	errorPrefix: string;
}): Promise<void> {
	const isQuotaExceededFailure = (details: string): boolean =>
		/\bquota_exceeded\b/i.test(details) && /\bmax_records\b/i.test(details);

	const waitForSearch = (maxAttempts?: number): Promise<void> =>
		waitForExpectedSearchHit({
			apiCall,
			indexName,
			query,
			expectedHitText,
			maxAttempts,
			errorPrefix
		});

	const runApiBatchFallback = async (primaryDetails: string): Promise<void> => {
		try {
			await ingestDocumentsViaApiBatch({
				apiCall,
				indexName,
				documents,
				errorPrefix
			});
			await waitForSearch();
			return;
		} catch (fallbackError) {
			const fallbackDetails =
				fallbackError instanceof Error ? fallbackError.message : String(fallbackError);
			if (isQuotaExceededFailure(fallbackDetails)) {
				// Quota-limited environments can reject fallback writes even when the
				// primary ingest succeeded and searchability only lagged readiness.
				await waitForSearch(60);
				return;
			}
			throw new Error(
				`${errorPrefix}: primary ingest path failed (${primaryDetails}); API batch fallback failed (${fallbackDetails})`
			);
		}
	};

	try {
		await primaryIngest();
	} catch (primaryError) {
		const primaryDetails =
			primaryError instanceof Error ? primaryError.message : String(primaryError);
		if (primaryIngestPath === 'api-batch') {
			throw new Error(`${errorPrefix}: API batch ingest failed (${primaryDetails})`);
		}
		await runApiBatchFallback(primaryDetails);
		return;
	}

	try {
		await waitForSearch();
		return;
	} catch (searchError) {
		const searchDetails = searchError instanceof Error ? searchError.message : String(searchError);
		if (primaryIngestPath === 'api-batch') {
			await waitForSearch(60);
			return;
		}
		await runApiBatchFallback(searchDetails);
	}
}

async function waitForSeededIndexByToken(
	apiUrl: string,
	token: string,
	name: string,
	fetchImpl: FetchImplFn = fetch
): Promise<void> {
	const maxAttempts = 60;

	for (let attempt = 0; attempt < maxAttempts; attempt++) {
		const res = await customerApiCallForToken(
			apiUrl,
			token,
			'GET',
			`/indexes/${encodeURIComponent(name)}`,
			undefined,
			fetchImpl
		);
		if (res.ok) {
			return;
		}
		if (res.status !== 404 && res.status !== 429 && res.status !== 500 && res.status !== 503) {
			throw new Error(
				`seedIndexForCustomer readiness check failed: ${res.status} ${await res.text()}`
			);
		}

		const delayMs = res.status === 429 ? getTransientRetryDelayMs(attempt) : 500;
		await sleep(delayMs);
	}

	throw new Error(`seedIndexForCustomer readiness check timed out for "${name}"`);
}

async function createIndexWithTransientRetries(params: {
	createOnce: () => Promise<Response>;
	errorPrefix: string;
}): Promise<void> {
	const { createOnce, errorPrefix } = params;

	// Local Playwright CI can report transient backend-unavailable while the
	// tenant/index route is warming.
	let lastFailure = 'none';

	for (let attempt = 0; attempt < INDEX_CREATE_MAX_RETRIES; attempt++) {
		const indexRes = await createOnce();
		if (indexRes.ok) {
			return;
		}

		const body = await indexRes.text();
		lastFailure = `${indexRes.status} ${body}`;

		// A retry can race with a previous successful create, which then surfaces
		// as a duplicate name on the next attempt even though the index exists.
		if (indexRes.status === 409 && attempt > 0) {
			return;
		}

		if (indexRes.status !== 429 && indexRes.status !== 500 && indexRes.status !== 503) {
			throw new Error(`${errorPrefix}: ${lastFailure}`);
		}

		const retryAfterSeconds = Number(indexRes.headers.get('retry-after') ?? '');
		const retryAfterMs =
			Number.isFinite(retryAfterSeconds) && retryAfterSeconds > 0 ? retryAfterSeconds * 1000 : 0;
		const backoffMs = getTransientRetryDelayMs(attempt);
		await sleep(Math.max(retryAfterMs, backoffMs));
	}

	throw new Error(`${errorPrefix} after transient create retries: ${lastFailure}`);
}

async function createIndexForCustomerWithRetries({
	apiUrl,
	adminKey,
	customerId,
	name,
	region,
	flapjackUrl,
	fetchImpl = fetch
}: CreateIndexForCustomerParams): Promise<void> {
	const createBody: Record<string, string> = {
		name,
		region
	};
	if (flapjackUrl) {
		createBody.flapjack_url = flapjackUrl;
	}

	await createIndexWithTransientRetries({
		createOnce: () =>
			adminApiCallForTenant(
				apiUrl,
				adminKey,
				'POST',
				`/admin/tenants/${encodeURIComponent(customerId)}/indexes`,
				createBody,
				fetchImpl
			),
		errorPrefix: 'seedIndexForCustomer failed'
	});
}

async function createIndexForCustomerViaTokenWithRetries({
	apiUrl,
	token,
	name,
	region,
	fetchImpl = fetch
}: CreateIndexForCustomerViaTokenParams): Promise<void> {
	await createIndexWithTransientRetries({
		createOnce: () =>
			customerApiCallForToken(
				apiUrl,
				token,
				'POST',
				'/indexes',
				{
					name,
					region
				},
				fetchImpl
			),
		errorPrefix: 'seedIndexForCustomer customer create failed'
	});
}

async function createIndexKeyWithRetries(
	apiCall: ApiCallFn,
	name: string,
	description: string,
	acl: string[]
): Promise<{ key: string }> {
	// Newly created tenant-index routes can stay in a transient unavailable
	// state longer than index creation/readiness checks, so key creation needs a
	// slightly wider retry budget than the other fixture steps.
	let lastFailure = 'none';

	for (let attempt = 0; attempt < INDEX_KEY_CREATE_MAX_RETRIES; attempt++) {
		const res = await apiCall('POST', `/indexes/${encodeURIComponent(name)}/keys`, {
			description,
			acl
		});

		if (res.ok) {
			return (await res.json()) as { key: string };
		}

		const body = await res.text();
		lastFailure = `${res.status} ${body}`;
		const endpointNotReady = responseHasEndpointNotReadyBody(res.status, body);

		// Flapjack can briefly report backend-unavailable while a newly created
		// tenant/index route is still warming after admin index creation.
		if (
			res.status !== 404 &&
			res.status !== 429 &&
			res.status !== 500 &&
			res.status !== 503 &&
			!endpointNotReady
		) {
			throw new Error(`seedSearchableIndex: key creation failed: ${lastFailure}`);
		}

		await sleepForTransientResponse(res, attempt);
	}

	throw new Error(`seedSearchableIndex: key creation failed after retries: ${lastFailure}`);
}

export async function seedIndexForCustomerViaAdmin({
	apiUrl,
	adminKey,
	customerId,
	token,
	name,
	region,
	flapjackUrl,
	fetchImpl = fetch
}: SeedIndexForCustomerViaAdminParams): Promise<void> {
	const normalizedAccess = normalizeSeedIndexAccess({
		adminKey,
		customerId,
		token,
		name,
		errorPrefix: 'seedIndexForCustomerViaAdmin'
	});

	await createIndexForCustomerWithRetries({
		apiUrl,
		adminKey: normalizedAccess.adminKey,
		customerId: normalizedAccess.customerId,
		name: normalizedAccess.name,
		region,
		flapjackUrl,
		fetchImpl
	});

	await waitForSeededIndexByToken(apiUrl, normalizedAccess.token, normalizedAccess.name, fetchImpl);
}

export async function seedSearchableIndexForCustomer({
	apiUrl,
	adminKey,
	customerId,
	token,
	name,
	region,
	flapjackUrl = process.env.FLAPJACK_URL?.trim(),
	query = DEFAULT_SEARCH_QUERY,
	expectedHitText = DEFAULT_EXPECTED_HIT_TEXT,
	documents = DEFAULT_DOCUMENTS,
	metricsReady,
	fetchImpl = fetch
}: SeedSearchableIndexForCustomerParams): Promise<SearchableIndexResult> {
	const normalizedAccess = normalizeSeedIndexAccess({
		adminKey,
		customerId,
		token,
		name,
		errorPrefix: 'seedSearchableIndexForCustomer'
	});
	const safeFlapjackUrl = resolveSeedFlapjackUrl(flapjackUrl);
	const directFlapjackEngineUrl =
		safeFlapjackUrl && isDirectFlapjackEngineUrl(safeFlapjackUrl) ? safeFlapjackUrl : undefined;
	const flapjackIndexUid = buildTenantScopedIndexUid(
		normalizedAccess.customerId,
		normalizedAccess.name
	);
	const metricsReadyOptions = resolveMetricsReadyOptions(metricsReady, documents);

	if (directFlapjackEngineUrl) {
		await seedIndexForCustomerViaAdmin({
			apiUrl,
			adminKey: normalizedAccess.adminKey,
			customerId: normalizedAccess.customerId,
			token: normalizedAccess.token,
			name: normalizedAccess.name,
			region,
			flapjackUrl: directFlapjackEngineUrl,
			fetchImpl
		});
	} else {
		await createIndexForCustomerViaTokenWithRetries({
			apiUrl,
			token: normalizedAccess.token,
			name: normalizedAccess.name,
			region,
			fetchImpl
		});
		await waitForSeededIndexByToken(
			apiUrl,
			normalizedAccess.token,
			normalizedAccess.name,
			fetchImpl
		);
	}

	const userApiCall: ApiCallFn = (method, path, body) =>
		customerApiCallForToken(apiUrl, normalizedAccess.token, method, path, body, fetchImpl);

	let primaryIngest: () => Promise<void>;
	let primaryIngestPath: PrimaryDocumentIngestPath;
	if (directFlapjackEngineUrl) {
		const { key } = await createIndexKeyWithRetries(
			userApiCall,
			normalizedAccess.name,
			buildIndexKeyDescription(normalizedAccess.name),
			['search', 'addObject']
		);
		primaryIngest = () =>
			ingestDocumentsViaFlapjack({
				flapjackUrl: directFlapjackEngineUrl,
				flapjackIndexName: flapjackIndexUid,
				key,
				documents,
				fetchImpl,
				errorPrefix: 'seedSearchableIndexForCustomer'
			});
		primaryIngestPath = 'direct-flapjack';
	} else {
		primaryIngest = () =>
			ingestDocumentsViaApiBatch({
				apiCall: userApiCall,
				indexName: normalizedAccess.name,
				documents,
				errorPrefix: 'seedSearchableIndexForCustomer'
			});
		primaryIngestPath = 'api-batch';
	}
	await ingestDocumentsWithSearchFallback({
		primaryIngest,
		primaryIngestPath,
		apiCall: userApiCall,
		indexName: normalizedAccess.name,
		query,
		expectedHitText,
		documents,
		errorPrefix: 'seedSearchableIndexForCustomer'
	});

	return buildSearchableIndexSeedResult({
		apiCall: userApiCall,
		indexName: normalizedAccess.name,
		query,
		expectedHitText,
		metricsReady: metricsReadyOptions,
		errorPrefix: 'seedSearchableIndexForCustomer'
	});
}

export function createSeedSearchableIndexFactory({
	testRegion,
	apiCall,
	adminApiCall,
	getCustomerId,
	waitForSeededIndex,
	flapjackUrl: injectedFlapjackUrl
}: SearchableIndexFactoryDeps): SeedSearchableIndexFn {
	return async (name, options = {}) => {
		const query = options.query ?? DEFAULT_SEARCH_QUERY;
		const expectedHitText = options.expectedHitText ?? DEFAULT_EXPECTED_HIT_TEXT;
		const documents = options.documents ?? DEFAULT_DOCUMENTS;
		const metricsReadyOptions = resolveMetricsReadyOptions(options.metricsReady, documents);
		// Use the injected URL if provided, otherwise fall back to contract default
		const flapjackUrl = requireLoopbackHttpUrl(
			'FLAPJACK_URL',
			injectedFlapjackUrl ?? DEFAULT_FLAPJACK_URL
		);
		const customerId = await getCustomerId();
		const flapjackIndexUid = buildTenantScopedIndexUid(customerId, name);
		const createBody = { name, region: testRegion, flapjack_url: flapjackUrl };

		// Seed the customer index against a real Flapjack endpoint so the browser
		// spec can exercise live preview behavior without creating the index via UI.
		await createIndexWithTransientRetries({
			createOnce: () =>
				adminApiCall(
					'POST',
					`/admin/tenants/${encodeURIComponent(customerId)}/indexes`,
					createBody
				),
			errorPrefix: 'seedSearchableIndex: index creation failed'
		});

		// The admin seed returns before the customer routes always see the index.
		// Poll the same read path the detail page and key creation depend on.
		await waitForSeededIndex(name);

		const { key } = await createIndexKeyWithRetries(apiCall, name, buildIndexKeyDescription(name), [
			'search',
			'addObject'
		]);

		await ingestDocumentsWithSearchFallback({
			primaryIngest: () =>
				ingestDocumentsViaFlapjack({
					flapjackUrl,
					flapjackIndexName: flapjackIndexUid,
					key,
					documents,
					errorPrefix: 'seedSearchableIndex'
				}),
			primaryIngestPath: 'direct-flapjack',
			apiCall,
			indexName: name,
			query,
			expectedHitText,
			documents,
			errorPrefix: 'seedSearchableIndex'
		});

		return buildSearchableIndexSeedResult({
			apiCall,
			indexName: name,
			query,
			expectedHitText,
			metricsReady: metricsReadyOptions,
			errorPrefix: 'seedSearchableIndex'
		});
	};
}
