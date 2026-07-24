/**
 * Same-origin adapter from the dashboard search widget's batch envelope to the
 * authenticated control-plane search route.
 */
import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { ApiRequestError } from '$lib/api/client';
import { createApiClient } from '$lib/server/api';

interface InstantSearchRequest {
	indexName: string;
	params: Record<string, unknown>;
}

// A fixed cap prevents one browser request from amplifying into unbounded API work.
const MAX_BATCH_REQUESTS = 10;

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function parseRequests(body: unknown): InstantSearchRequest[] | null {
	if (!isRecord(body) || !Array.isArray(body.requests)) return null;

	for (const request of body.requests) {
		if (!isRecord(request) || typeof request.indexName !== 'string' || !isRecord(request.params)) {
			return null;
		}
	}

	return body.requests as InstantSearchRequest[];
}

export const POST: RequestHandler = async ({ request, locals, params }) => {
	const sessionToken = locals.user?.token;
	if (!sessionToken) {
		return json({ error: 'unauthorized' }, { status: 401 });
	}

	let body: unknown;
	try {
		body = await request.json();
	} catch {
		return json({ error: 'invalid search payload' }, { status: 400 });
	}

	const requests = parseRequests(body);
	if (requests === null) {
		return json({ error: 'invalid search payload' }, { status: 400 });
	}
	if (requests.length > MAX_BATCH_REQUESTS) {
		return json({ error: 'too many search requests' }, { status: 400 });
	}
	// The route parameter is the authenticated tenant-facing index owner. Never
	// allow a batch item to substitute another index name.
	if (requests.some((searchRequest) => searchRequest.indexName !== params.name)) {
		return json({ error: 'invalid search payload' }, { status: 400 });
	}

	try {
		const api = createApiClient(sessionToken);
		const results = [];
		// Sequential forwarding preserves response order and bounds concurrency to
		// one control-plane request without adding a queue or worker abstraction.
		for (const searchRequest of requests) {
			results.push(await api.testSearch(params.name, searchRequest.params));
		}
		return json({ results });
	} catch (error) {
		if (error instanceof ApiRequestError) {
			const message =
				error.status === 404
					? 'Search data is unavailable for this index. Refresh and retry.'
					: error.message;
			return json({ error: message }, { status: error.status });
		}
		return json(
			{ error: error instanceof Error ? error.message : 'search failed' },
			{ status: 500 }
		);
	}
};
