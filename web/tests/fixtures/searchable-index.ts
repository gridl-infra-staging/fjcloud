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
type JsonHeaders = Record<string, string>;

export type SearchableIndexResult = {
	name: string;
	query: string;
	expectedHitText: string;
};

export type SeedSearchableIndexFn = (name: string) => Promise<SearchableIndexResult>;

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
};

type CreateIndexForCustomerParams = Omit<
	SeedIndexForCustomerViaAdminParams,
	'token' | 'adminKey'
> & {
	adminKey: string;
};

type SearchableIndexFactoryDeps = {
	testRegion: string;
	apiCall: ApiCallFn;
	adminApiCall: AdminApiCallFn;
	getCustomerId: GetCustomerIdFn;
	waitForSeededIndex: WaitForSeededIndexFn;
	/** Optional flapjack URL override for admin index creation. Defaults to contract DEFAULT_FLAPJACK_URL. */
	flapjackUrl?: string;
};

const DEFAULT_DOCUMENTS: Array<Record<string, unknown>> = [
	{
		id: 'doc-1',
		title: 'Rust Programming Language',
		body: 'Systems programming',
		category: 'tech'
	},
	{
		id: 'doc-2',
		title: 'TypeScript Handbook',
		body: 'JavaScript with types',
		category: 'tech'
	},
	{
		id: 'doc-3',
		title: 'Rust Async Book',
		body: 'Futures and async/await in Rust',
		category: 'tech'
	}
];
const DEFAULT_SEARCH_QUERY = 'Rust';
const DEFAULT_EXPECTED_HIT_TEXT = 'Rust Programming Language';
const JSON_CONTENT_TYPE = { 'Content-Type': 'application/json' } as const;

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

function getTransientRetryDelayMs(attempt: number): number {
	return Math.min(2000 * (attempt + 1), 10_000);
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
	for (let attempt = 0; attempt < maxAttempts; attempt++) {
		const searchRes = await apiCall('POST', `/indexes/${encodeURIComponent(indexName)}/search`, {
			query
		});
		if (searchRes.ok) {
			const searchData = (await searchRes.json()) as SearchHitsResponse;
			if (searchData.hits?.some((hit) => hit.title?.includes(expectedHitText))) {
				return;
			}
		}
		await sleep(pollIntervalMs);
	}

	throw new Error(`${errorPrefix}: documents not searchable after ${maxAttempts} attempts`);
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
		if (res.status !== 404 && res.status !== 429 && res.status !== 500) {
			throw new Error(
				`seedIndexForCustomer readiness check failed: ${res.status} ${await res.text()}`
			);
		}

		const delayMs = res.status === 429 ? getTransientRetryDelayMs(attempt) : 500;
		await sleep(delayMs);
	}

	throw new Error(`seedIndexForCustomer readiness check timed out for "${name}"`);
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

	const maxRetries = 6;
	let lastFailure = 'none';

	for (let attempt = 0; attempt < maxRetries; attempt++) {
		const indexRes = await adminApiCallForTenant(
			apiUrl,
			adminKey,
			'POST',
			`/admin/tenants/${encodeURIComponent(customerId)}/indexes`,
			createBody,
			fetchImpl
		);
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

		if (indexRes.status !== 429 && indexRes.status !== 500) {
			throw new Error(`seedIndexForCustomer failed: ${lastFailure}`);
		}

		await sleep(getTransientRetryDelayMs(attempt));
	}

	throw new Error(`seedIndexForCustomer failed after transient create retries: ${lastFailure}`);
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
	const maxRetries = 10;
	let lastFailure = 'none';

	for (let attempt = 0; attempt < maxRetries; attempt++) {
		const res = await apiCall('POST', `/indexes/${encodeURIComponent(name)}/keys`, {
			description,
			acl
		});

		if (res.ok) {
			return (await res.json()) as { key: string };
		}

		const body = await res.text();
		lastFailure = `${res.status} ${body}`;
		const normalizedBody = body.toLowerCase();
		const endpointNotReady =
			res.status === 400 && normalizedBody.includes('endpoint not ready yet');

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

		const retryAfterSeconds = Number(res.headers.get('retry-after') ?? '');
		const retryAfterMs =
			Number.isFinite(retryAfterSeconds) && retryAfterSeconds > 0 ? retryAfterSeconds * 1000 : 0;
		const backoffMs = getTransientRetryDelayMs(attempt);
		await sleep(Math.max(retryAfterMs, backoffMs));
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
	flapjackUrl = DEFAULT_FLAPJACK_URL,
	query = DEFAULT_SEARCH_QUERY,
	expectedHitText = DEFAULT_EXPECTED_HIT_TEXT,
	documents = DEFAULT_DOCUMENTS,
	fetchImpl = fetch
}: SeedSearchableIndexForCustomerParams): Promise<SearchableIndexResult> {
	const normalizedAccess = normalizeSeedIndexAccess({
		adminKey,
		customerId,
		token,
		name,
		errorPrefix: 'seedSearchableIndexForCustomer'
	});
	const safeFlapjackUrl = requireLoopbackHttpUrl('FLAPJACK_URL', flapjackUrl);
	const flapjackIndexUid = buildTenantScopedIndexUid(
		normalizedAccess.customerId,
		normalizedAccess.name
	);

	await seedIndexForCustomerViaAdmin({
		apiUrl,
		adminKey: normalizedAccess.adminKey,
		customerId: normalizedAccess.customerId,
		token: normalizedAccess.token,
		name: normalizedAccess.name,
		region,
		flapjackUrl: safeFlapjackUrl,
		fetchImpl
	});

	const userApiCall: ApiCallFn = (method, path, body) =>
		customerApiCallForToken(apiUrl, normalizedAccess.token, method, path, body, fetchImpl);

	const { key } = await createIndexKeyWithRetries(
		userApiCall,
		normalizedAccess.name,
		buildIndexKeyDescription(normalizedAccess.name),
		['search', 'addObject']
	);
	await ingestDocumentsViaFlapjack({
		flapjackUrl: safeFlapjackUrl,
		flapjackIndexName: flapjackIndexUid,
		key,
		documents,
		fetchImpl,
		errorPrefix: 'seedSearchableIndexForCustomer'
	});
	await waitForExpectedSearchHit({
		apiCall: userApiCall,
		indexName: normalizedAccess.name,
		query,
		expectedHitText,
		errorPrefix: 'seedSearchableIndexForCustomer'
	});

	return {
		name: normalizedAccess.name,
		query,
		expectedHitText
	};
}

export function createSeedSearchableIndexFactory({
	testRegion,
	apiCall,
	adminApiCall,
	getCustomerId,
	waitForSeededIndex,
	flapjackUrl: injectedFlapjackUrl
}: SearchableIndexFactoryDeps): SeedSearchableIndexFn {
	return async (name) => {
		// Use the injected URL if provided, otherwise fall back to contract default
		const flapjackUrl = requireLoopbackHttpUrl(
			'FLAPJACK_URL',
			injectedFlapjackUrl ?? DEFAULT_FLAPJACK_URL
		);
		const customerId = await getCustomerId();
		const flapjackIndexUid = buildTenantScopedIndexUid(customerId, name);

		// Seed the customer index against a real Flapjack endpoint so the browser
		// spec can exercise live preview behavior without creating the index via UI.
		const indexRes = await adminApiCall(
			'POST',
			`/admin/tenants/${encodeURIComponent(customerId)}/indexes`,
			{ name, region: testRegion, flapjack_url: flapjackUrl }
		);
		if (!indexRes.ok) {
			throw new Error(
				`seedSearchableIndex: index creation failed: ${indexRes.status} ${await indexRes.text()}`
			);
		}

		// The admin seed returns before the customer routes always see the index.
		// Poll the same read path the detail page and key creation depend on.
		await waitForSeededIndex(name);

		const { key } = await createIndexKeyWithRetries(apiCall, name, buildIndexKeyDescription(name), [
			'search',
			'addObject'
		]);

		const query = DEFAULT_SEARCH_QUERY;
		const expectedHitText = DEFAULT_EXPECTED_HIT_TEXT;
		await ingestDocumentsViaFlapjack({
			flapjackUrl,
			flapjackIndexName: flapjackIndexUid,
			key,
			documents: DEFAULT_DOCUMENTS,
			errorPrefix: 'seedSearchableIndex'
		});
		await waitForExpectedSearchHit({
			apiCall,
			indexName: name,
			query,
			expectedHitText,
			errorPrefix: 'seedSearchableIndex'
		});

		return { name, query, expectedHitText };
	};
}
