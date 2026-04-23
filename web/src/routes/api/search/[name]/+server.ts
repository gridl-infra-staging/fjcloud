/**
 * @module Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/web/src/routes/api/search/[name]/+server.ts.
 */
import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { executeIndexSearch } from '$lib/server/index-search';
import { ApiRequestError } from '$lib/api/client';

interface InstantSearchRequest {
	indexName: string;
	params: Record<string, unknown>;
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function parseRequests(body: unknown): InstantSearchRequest[] | null {
	if (!isRecord(body)) {
		return null;
	}

	if (!Object.prototype.hasOwnProperty.call(body, 'requests')) {
		return null;
	}

	const { requests } = body;
	if (!Array.isArray(requests)) {
		return null;
	}

	for (const request of requests) {
		if (!isRecord(request)) {
			return null;
		}

		if (!isRecord(request.params)) {
			return null;
		}
	}

	return requests as InstantSearchRequest[];
}

export const POST: RequestHandler = async ({ request, locals, params }) => {
	if (!locals.user) {
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

	try {
		const results = await Promise.all(
			requests.map((req) => executeIndexSearch(locals.user!.token, params.name, req.params))
		);
		return json({ results });
	} catch (e) {
		if (e instanceof ApiRequestError) {
			return json({ error: e.message }, { status: e.status });
		}
		const message = e instanceof Error ? e.message : 'search failed';
		return json({ error: message }, { status: 500 });
	}
};
