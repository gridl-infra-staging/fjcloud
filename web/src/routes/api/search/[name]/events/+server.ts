/** Same-origin JWT adapter for one query-correlated search preview event. */
import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { ApiRequestError } from '$lib/api/client';
import type { PreviewEventRequest } from '$lib/api/types';
import { createApiClient } from '$lib/server/api';

function parseEvent(body: unknown): PreviewEventRequest | null {
	if (!body || typeof body !== 'object' || Array.isArray(body)) return null;
	const value = body as Record<string, unknown>;
	if (
		value.eventName !== 'search_preview_result_opened' ||
		typeof value.objectID !== 'string' ||
		typeof value.position !== 'number' ||
		typeof value.queryID !== 'string' ||
		typeof value.timestamp !== 'number' ||
		typeof value.userToken !== 'string'
	) {
		return null;
	}
	return {
		eventName: value.eventName,
		objectID: value.objectID,
		position: value.position,
		queryID: value.queryID,
		timestamp: value.timestamp,
		userToken: value.userToken
	};
}

export const POST: RequestHandler = async ({ request, locals, params }) => {
	const sessionToken = locals.user?.token;
	if (!sessionToken) return json({ error: 'unauthorized' }, { status: 401 });

	let event: PreviewEventRequest | null = null;
	try {
		event = parseEvent(await request.json());
	} catch {
		// The common invalid-payload response deliberately covers malformed JSON.
	}
	if (!event) return json({ error: 'invalid preview event payload' }, { status: 400 });

	try {
		return json(await createApiClient(sessionToken).postPreviewEvent(params.name, event));
	} catch (error) {
		if (error instanceof ApiRequestError) {
			return json({ error: error.message }, { status: error.status });
		}
		return json(
			{ error: error instanceof Error ? error.message : 'preview event failed' },
			{ status: 500 }
		);
	}
};
