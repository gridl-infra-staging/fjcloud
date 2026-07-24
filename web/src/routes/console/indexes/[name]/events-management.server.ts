import { fail } from '@sveltejs/kit';
import { ApiRequestError } from '$lib/api/client';
import { createApiClient } from '$lib/server/api';
import { mapDashboardSessionFailure } from '$lib/server/auth-action-errors';
import { errorMessage, parsePositiveInt } from './document-management.server';

const DEFAULT_EVENTS_REFRESH_LIMIT = 100;
const MAX_EVENTS_REFRESH_LIMIT = 1000;

type RefreshEventsActionArgs = {
	request: Request;
	indexName: string;
	token: string | undefined;
};

function failForEventsAction<T extends Record<string, unknown>>(error: unknown, payload: T) {
	const sessionFailure = mapDashboardSessionFailure(error);
	if (sessionFailure) return sessionFailure;
	return fail(400, payload);
}

function refreshEventsErrorMessage(error: unknown): string {
	if (error instanceof ApiRequestError) {
		return 'Failed to fetch events';
	}
	return errorMessage(error, 'Failed to fetch events');
}

export async function refreshEventsAction({ request, indexName, token }: RefreshEventsActionArgs) {
	const data = await request.formData();
	const eventType = (data.get('eventType') as string) || undefined;
	const status = (data.get('status') as string) || undefined;
	let limit = DEFAULT_EVENTS_REFRESH_LIMIT;
	let from: number | undefined;
	let until: number | undefined;

	try {
		const limitRaw = (data.get('limit') as string | null)?.trim() ?? '';
		if (limitRaw) {
			limit = Math.min(parsePositiveInt(limitRaw, 'limit'), MAX_EVENTS_REFRESH_LIMIT);
		}

		const fromRaw = (data.get('from') as string | null)?.trim() ?? '';
		if (fromRaw) {
			from = parsePositiveInt(fromRaw, 'from');
		}

		const untilRaw = (data.get('until') as string | null)?.trim() ?? '';
		if (untilRaw) {
			until = parsePositiveInt(untilRaw, 'until');
		}
	} catch (e) {
		return failForEventsAction(e, { eventsError: errorMessage(e, 'Invalid event filters') });
	}

	const api = createApiClient(token);
	try {
		const result = await api.getDebugEvents(indexName, {
			eventType,
			status,
			limit,
			from,
			until
		});
		return { refreshedEvents: result };
	} catch (e) {
		return failForEventsAction(e, { eventsError: refreshEventsErrorMessage(e) });
	}
}
