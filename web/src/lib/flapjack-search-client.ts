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

export type InstantSearchResponse = {
	results: unknown[];
};

export const FLAPJACK_SEARCH_APP_ID = 'griddle' as const;

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
		// Keep the browser preview path aligned with the public SDK snippets on the
		// same page so we only have one live client contract to maintain.
		baseHeaders: {
			Authorization: `Bearer ${apiKey}`
		}
	};
}

export function createFlapjackInstantSearchClient(
	endpoint: string,
	apiKey: string
): {
	search(requests: InstantSearchRequest[]): Promise<InstantSearchResponse>;
	searchForFacetValues(): Promise<{ results: never[] }>;
	clearCache(): void;
} {
	const searchUrl = `${endpoint.replace(/\/+$/, '')}/1/indexes/*/queries`;

	return {
		/**
		 * TODO: Document search.
		 */
		async search(requests: InstantSearchRequest[]): Promise<InstantSearchResponse> {
			if (requests.length === 0) {
				return { results: [] };
			}

			const response = await fetch(searchUrl, {
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					'X-Algolia-API-Key': apiKey,
					'X-Algolia-Application-Id': FLAPJACK_SEARCH_APP_ID,
					// Keep the live widget aligned with the browser-facing SDK snippets,
					// while still sending the native Algolia-compatible auth headers that
					// Flapjack accepts on direct search routes today.
					Authorization: `Bearer ${apiKey}`
				},
				body: JSON.stringify({ requests })
			});

			if (!response.ok) {
				throw new Error(`Flapjack search failed: ${response.status}`);
			}

			return (await response.json()) as InstantSearchResponse;
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
