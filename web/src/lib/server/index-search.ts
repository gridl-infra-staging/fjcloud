import { createApiClient } from '$lib/server/api';
import type { SearchResult } from '$lib/api/types';

/**
 * Execute a search against an index via the authenticated API.
 * Shared by the form-action search in +page.server.ts and the
 * InstantSearch proxy in /api/search/[name]/+server.ts.
 */
export async function executeIndexSearch(
	token: string | undefined,
	indexName: string,
	params: Record<string, unknown>
): Promise<SearchResult> {
	const api = createApiClient(token);
	return api.testSearch(indexName, params);
}
