/**
 * @module Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar19_2_feature_gaps/fjcloud_dev/web/src/routes/dashboard/migrate/+page.server.ts.
 */
import { fail } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import { createApiClient } from '$lib/server/api';
import { ApiRequestError } from '$lib/api/client';
import { customerFacingErrorMessage, mapDashboardSessionFailure } from '$lib/server/auth-action-errors';

const GENERIC_ACTION_ERROR = 'An unexpected error occurred';

function actionFailure(err: unknown): { status: 400 | 500 | 503; message: string } {
	if (err instanceof ApiRequestError && err.status === 503) {
		return { status: 503, message: 'No active deployment available' };
	}

	if (err instanceof ApiRequestError && err.status === 400) {
		return { status: 400, message: customerFacingErrorMessage(err, GENERIC_ACTION_ERROR) };
	}

	return { status: 500, message: GENERIC_ACTION_ERROR };
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === 'object' && value !== null;
}

type ParsedCredentials =
	| { appId: string; apiKey: string }
	| { error: string };

function parseAlgoliaCredentials(formData: FormData): ParsedCredentials {
	const appId = (formData.get('appId') as string | null)?.trim();
	const apiKey = (formData.get('apiKey') as string | null)?.trim();

	if (!appId) {
		return { error: 'App ID is required' };
	}

	if (!apiKey) {
		return { error: 'API Key is required' };
	}

	return { appId, apiKey };
}

function parseIndexListResponse(result: unknown): { indexes: unknown[] } {
	if (!isRecord(result)) {
		throw new Error('Unexpected list-indexes response from API');
	}

	const indexes =
		Array.isArray(result.indexes) ? result.indexes
		: Array.isArray(result.items) ? result.items
		: null;
	if (!indexes) {
		throw new Error('Unexpected list-indexes response from API');
	}

	return { indexes };
}

function parseMigrationStartResponse(result: unknown): { taskId: string; message: string } {
	if (!isRecord(result)) {
		throw new Error('Unexpected migration response from API');
	}

	const taskId = result.taskId ?? result.taskID;
	if (typeof taskId !== 'string' && typeof taskId !== 'number') {
		throw new Error('Unexpected migration response from API');
	}

	const message =
		typeof result.message === 'string' && result.message.length > 0 ? result.message
		: typeof result.status === 'string' && result.status.length > 0 ? result.status
		: 'Migration started';

	return {
		taskId: String(taskId),
		message
	};
}

export const load: PageServerLoad = async () => {
	return {};
};

export const actions = {
	listIndexes: async ({ request, locals }) => {
		const formData = await request.formData();
		const credentials = parseAlgoliaCredentials(formData);
		if ('error' in credentials) {
			return fail(400, { error: credentials.error });
		}

		const api = createApiClient(locals.user?.token);
		try {
			const result = parseIndexListResponse(await api.listAlgoliaIndexes(credentials));
			// Only return appId (identifier) — apiKey stays server-side
			return { indexes: result.indexes, appId: credentials.appId };
		} catch (err) {
			const sessionFailure = mapDashboardSessionFailure(err);
			if (sessionFailure) return sessionFailure;
			const { status, message } = actionFailure(err);
			return fail(status, { error: message });
		}
	},

	migrate: async ({ request, locals }) => {
		const formData = await request.formData();
		const credentials = parseAlgoliaCredentials(formData);
		if ('error' in credentials) {
			return fail(400, { error: credentials.error });
		}

		const sourceIndex = (formData.get('sourceIndex') as string | null)?.trim();
		if (!sourceIndex) {
			return fail(400, { error: 'Source index is required' });
		}

		const api = createApiClient(locals.user?.token);
		try {
			const result = parseMigrationStartResponse(
				await api.migrateFromAlgolia({ ...credentials, sourceIndex })
			);
			return {
				migrationStarted: true,
				taskId: result.taskId,
				message: result.message
			};
		} catch (err) {
			const sessionFailure = mapDashboardSessionFailure(err);
			if (sessionFailure) return sessionFailure;
			const { status, message } = actionFailure(err);
			return fail(status, { error: message });
		}
	}
} satisfies Actions;
