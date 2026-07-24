export type FlapjackSearchProtocol = 'http' | 'https';

export type FlapjackSearchHost = {
	url: string;
	accept: 'readWrite';
	protocol: FlapjackSearchProtocol;
};

export type InstantSearchRequest = {
	indexName: string;
	params?: string;
};

type InstantSearchProxyRequest = {
	indexName: string;
	params: Record<string, unknown>;
};

export type SearchPreviewParamsInput = {
	query: string;
	facets?: string[];
	facetFilters?: string[][];
	filters?: string;
	page?: number;
	hitsPerPage?: number;
	attributesToHighlight?: string[];
	analytics?: boolean;
	clickAnalytics?: boolean;
};

export type InstantSearchResponse = {
	results: NormalizedInstantSearchResult[];
};

export type NormalizedInstantSearchResult = Record<string, unknown> & {
	facets: Record<string, Record<string, number>>;
	hits?: Array<Record<string, unknown>>;
};

export const FLAPJACK_SEARCH_APP_ID = 'flapjack' as const;

const JSON_SEARCH_PARAM_KEYS = new Set(['facets', 'facetFilters', 'attributesToHighlight']);
const NUMBER_SEARCH_PARAM_KEYS = new Set(['page', 'hitsPerPage']);
const BOOLEAN_SEARCH_PARAM_KEYS = new Set(['analytics', 'clickAnalytics']);

export function buildSearchPreviewParams(input: SearchPreviewParamsInput): string {
	const params = new URLSearchParams();
	params.set('query', input.query);

	if (input.facets && input.facets.length > 0) {
		params.set('facets', JSON.stringify(input.facets));
	}
	if (input.facetFilters && input.facetFilters.length > 0) {
		params.set('facetFilters', JSON.stringify(input.facetFilters));
	}
	if (input.filters) {
		params.set('filters', input.filters);
	}
	if (typeof input.page === 'number') {
		params.set('page', String(input.page));
	}
	if (typeof input.hitsPerPage === 'number') {
		params.set('hitsPerPage', String(input.hitsPerPage));
	}
	if (input.attributesToHighlight && input.attributesToHighlight.length > 0) {
		params.set('attributesToHighlight', JSON.stringify(input.attributesToHighlight));
	}
	if (typeof input.analytics === 'boolean') {
		params.set('analytics', String(input.analytics));
	}
	if (typeof input.clickAnalytics === 'boolean') {
		params.set('clickAnalytics', String(input.clickAnalytics));
	}

	return params.toString();
}

export function parseFlapjackSearchEndpoint(endpoint: string): {
	host: string;
	protocol: FlapjackSearchProtocol;
} {
	const parsedUrl = new URL(endpoint);

	if (parsedUrl.protocol !== 'http:' && parsedUrl.protocol !== 'https:') {
		throw new TypeError(`Unsupported endpoint protocol: ${parsedUrl.protocol}`);
	}

	return {
		host: parsedUrl.host,
		protocol: parsedUrl.protocol.slice(0, -1) as FlapjackSearchProtocol
	};
}

export function buildFlapjackSearchHost(endpoint: string): FlapjackSearchHost {
	const { host, protocol } = parseFlapjackSearchEndpoint(endpoint);
	return {
		url: host,
		accept: 'readWrite',
		protocol
	};
}

export function buildFlapjackSearchClientOptions(
	endpoint: string,
	apiKey: string
): {
	hosts: [FlapjackSearchHost];
	baseHeaders: { Authorization: string };
} {
	return {
		hosts: [buildFlapjackSearchHost(endpoint)],
		// This helper belongs only to customer application snippets. Dashboard
		// Search uses the separate same-origin JWT transport below.
		baseHeaders: {
			Authorization: `Bearer ${apiKey}`
		}
	};
}

function searchProxyUrl(indexName: string): string {
	return `/api/search/${encodeURIComponent(indexName)}`;
}

function searchParamsStringToObject(params = ''): Record<string, unknown> {
	const parsedParams: Record<string, unknown> = {};
	for (const [key, value] of new URLSearchParams(params)) {
		parsedParams[key] = parseSearchParamValue(key, value);
	}
	return parsedParams;
}

function parseSearchParamValue(key: string, value: string): unknown {
	if (BOOLEAN_SEARCH_PARAM_KEYS.has(key) && (value === 'true' || value === 'false')) {
		return value === 'true';
	}
	if (NUMBER_SEARCH_PARAM_KEYS.has(key)) {
		const numericValue = Number(value);
		return Number.isFinite(numericValue) ? numericValue : value;
	}

	if (JSON_SEARCH_PARAM_KEYS.has(key)) {
		try {
			return JSON.parse(value) as unknown;
		} catch {
			return value;
		}
	}

	return value;
}

function buildSearchRequestBody(requests: InstantSearchRequest[]): string {
	const proxyRequests: InstantSearchProxyRequest[] = requests.map((request) => ({
		indexName: request.indexName,
		params: searchParamsStringToObject(request.params)
	}));

	return JSON.stringify({ requests: proxyRequests });
}
function normalizeFacetCounts(value: unknown): Record<string, Record<string, number>> {
	if (!value || typeof value !== 'object' || Array.isArray(value)) {
		return {};
	}

	const normalized: Record<string, Record<string, number>> = {};
	for (const [attribute, rawCounts] of Object.entries(value)) {
		if (!rawCounts || typeof rawCounts !== 'object' || Array.isArray(rawCounts)) {
			continue;
		}
		const counts: Record<string, number> = {};
		for (const [facetValue, rawCount] of Object.entries(rawCounts)) {
			if (typeof rawCount === 'number' && Number.isFinite(rawCount) && rawCount >= 0) {
				counts[facetValue] = rawCount;
			}
		}
		normalized[attribute] = counts;
	}
	return normalized;
}

/** Normalize the documented engine response once, before UI components consume it. */
export function normalizeInstantSearchResponse(payload: unknown): InstantSearchResponse {
	if (
		!payload ||
		typeof payload !== 'object' ||
		!Array.isArray((payload as { results?: unknown }).results)
	) {
		return { results: [] };
	}

	return {
		results: (payload as { results: unknown[] }).results.map((rawResult) => {
			if (!rawResult || typeof rawResult !== 'object' || Array.isArray(rawResult)) {
				return { facets: {} };
			}
			const result = rawResult as Record<string, unknown>;
			// Compatibility aliases were never part of the supported wire contract. Dropping
			// them here prevents components and fixtures from silently depending on them again.
			const documentedResult = { ...result };
			delete documentedResult.facetDistribution;
			delete documentedResult.facetsDistribution;
			return { ...documentedResult, facets: normalizeFacetCounts(result.facets) };
		})
	};
}

/** Build the dashboard-only client; the browser session authenticates same-origin requests. */
export function createDashboardInstantSearchClient(indexName: string): {
	search(requests: InstantSearchRequest[]): Promise<InstantSearchResponse>;
	searchForFacetValues(): Promise<{ results: never[] }>;
	clearCache(): void;
} {
	return {
		async search(requests: InstantSearchRequest[]): Promise<InstantSearchResponse> {
			if (requests.length === 0) {
				return { results: [] };
			}

			const response = await fetch(searchProxyUrl(indexName), {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: buildSearchRequestBody(requests)
			});

			if (!response.ok) {
				throw new Error(`Flapjack search failed: ${response.status}`);
			}

			return normalizeInstantSearchResponse(await response.json());
		},
		async searchForFacetValues() {
			return { results: [] };
		},
		clearCache() {
			// No local cache yet. Expose the hook so InstantSearch can treat this
			// client like the standard Algolia-compatible clients.
		}
	};
}
