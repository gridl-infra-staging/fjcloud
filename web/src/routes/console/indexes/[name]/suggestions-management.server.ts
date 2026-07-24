import { fail } from '@sveltejs/kit';
import { createApiClient } from '$lib/server/api';
import { mapDashboardSessionFailure } from '$lib/server/auth-action-errors';
import type { QsConfig } from '$lib/api/types';
import { errorMessage, parseJsonObject } from './document-management.server';

type SuggestionsActionArgs = {
	request: Request;
	indexName: string;
	token: string | undefined;
};

function failForSuggestionsAction<T extends Record<string, unknown>>(error: unknown, payload: T) {
	const sessionFailure = mapDashboardSessionFailure(error);
	if (sessionFailure) return sessionFailure;
	return fail(400, payload);
}

export async function saveQsConfigAction({ request, indexName, token }: SuggestionsActionArgs) {
	const data = await request.formData();
	const rawConfig = (data.get('config') as string)?.trim();
	if (!rawConfig) return fail(400, { qsConfigError: 'Suggestions config JSON is required' });

	let config: QsConfig;
	try {
		config = parseJsonObject<QsConfig>(rawConfig, 'config');
	} catch (error) {
		return failForSuggestionsAction(error, {
			qsConfigError: errorMessage(error, 'Invalid suggestions config JSON')
		});
	}

	const api = createApiClient(token);
	try {
		await api.saveQsConfig(indexName, config);
		return { qsConfigSaved: true };
	} catch (error) {
		return failForSuggestionsAction(error, {
			qsConfigError: errorMessage(error, 'Failed to save suggestions config')
		});
	}
}

export async function deleteQsConfigAction({
	indexName,
	token
}: Omit<SuggestionsActionArgs, 'request'>) {
	const api = createApiClient(token);
	try {
		await api.deleteQsConfig(indexName);
		return { qsConfigDeleted: true };
	} catch (error) {
		return failForSuggestionsAction(error, {
			qsConfigError: errorMessage(error, 'Failed to delete suggestions config')
		});
	}
}

export async function rebuildQsConfigAction({
	indexName,
	token
}: Omit<SuggestionsActionArgs, 'request'>) {
	const api = createApiClient(token);
	try {
		await api.triggerQsBuild(indexName);
		return { qsBuildQueued: true };
	} catch (error) {
		return failForSuggestionsAction(error, {
			qsConfigError: errorMessage(error, 'Failed to queue suggestions rebuild')
		});
	}
}
