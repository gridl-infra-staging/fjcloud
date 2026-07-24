import { fail } from '@sveltejs/kit';
import type { ApiClient } from '$lib/api/client';
import { createApiClient } from '$lib/server/api';
import { mapDashboardSessionFailure } from '$lib/server/auth-action-errors';
import { retryTransientDashboardApiRequest } from '$lib/server/transient-api-retry';
import type { Synonym, SynonymSearchResponse } from '$lib/api/types';
import { errorMessage, parseJsonObject } from './document-management.server';

type SynonymActionArgs = {
	request: Request;
	indexName: string;
	token: string | undefined;
};

function failForSynonymAction<T extends Record<string, unknown>>(error: unknown, payload: T) {
	const sessionFailure = mapDashboardSessionFailure(error);
	if (sessionFailure) return sessionFailure;
	return fail(400, payload);
}

export async function loadSynonymsPayload(
	api: ApiClient,
	indexName: string,
	query: string
): Promise<SynonymSearchResponse | null> {
	try {
		return await api.searchSynonyms(indexName, query);
	} catch {
		return null;
	}
}

export async function saveSynonymAction({ request, indexName, token }: SynonymActionArgs) {
	const data = await request.formData();
	const objectID = (data.get('objectID') as string)?.trim();
	const rawSynonym = (data.get('synonym') as string)?.trim();
	if (!objectID) return fail(400, { synonymError: 'objectID is required' });
	if (!rawSynonym) return fail(400, { synonymError: 'Synonym JSON is required' });

	let synonym: Synonym;
	try {
		synonym = parseJsonObject<Synonym>(rawSynonym, 'synonym');
	} catch (error) {
		return failForSynonymAction(error, {
			synonymError: errorMessage(error, 'Invalid synonym JSON')
		});
	}

	const api = createApiClient(token);
	try {
		await retryTransientDashboardApiRequest(() => api.saveSynonym(indexName, objectID, synonym));
		return { synonymSaved: true };
	} catch (error) {
		return failForSynonymAction(error, {
			synonymError: errorMessage(error, 'Failed to save synonym')
		});
	}
}

export async function deleteSynonymAction({ request, indexName, token }: SynonymActionArgs) {
	const data = await request.formData();
	const objectID = (data.get('objectID') as string)?.trim();
	if (!objectID) return fail(400, { synonymError: 'objectID is required' });

	const api = createApiClient(token);
	try {
		await retryTransientDashboardApiRequest(() => api.deleteSynonym(indexName, objectID));
		return { synonymDeleted: true };
	} catch (error) {
		return failForSynonymAction(error, {
			synonymError: errorMessage(error, 'Failed to delete synonym')
		});
	}
}

export async function clearSynonymsAction({ indexName, token }: SynonymActionArgs) {
	const api = createApiClient(token);
	try {
		await retryTransientDashboardApiRequest(() => api.clearSynonyms(indexName));
		return { synonymsCleared: true };
	} catch (error) {
		return failForSynonymAction(error, {
			synonymError: errorMessage(error, 'Failed to clear synonyms')
		});
	}
}
