/**
 * @module Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/web/src/routes/dashboard/indexes/[name]/dictionary-management.server.ts.
 */
import { fail } from '@sveltejs/kit';
import type { ApiClient } from '$lib/api/client';
import { createApiClient } from '$lib/server/api';
import { mapDashboardSessionFailure } from '$lib/server/auth-action-errors';
import type {
	DictionaryBatchRequest,
	DictionaryLanguagesResponse,
	DictionaryName,
	DictionarySearchResponse
} from '$lib/api/types';
import { errorMessage } from './document-management.server';
import {
	type DictionarySelection,
	parseDictionaryEntryFromForm,
	parseDictionarySelectionFromForm,
	resolveDictionaryName,
	resolveDictionarySelection
} from './dictionary-helpers.server';

export const EMPTY_DICTIONARY_ENTRIES: DictionarySearchResponse = {
	hits: [],
	nbHits: 0,
	page: 0,
	nbPages: 0
};

export interface DictionariesPayload extends DictionarySelection {
	languages: DictionaryLanguagesResponse | null;
	entries: DictionarySearchResponse;
}

type DictionaryActionArgs = {
	request: Request;
	indexName: string;
	token: string | undefined;
};

interface CanonicalDictionariesPayloadResult {
	payload: DictionariesPayload;
	requestError: string | null;
	sessionFailure: ReturnType<typeof mapDashboardSessionFailure>;
}

export function emptyDictionariesPayload(): DictionariesPayload {
	return {
		languages: null,
		selectedDictionary: 'stopwords',
		selectedLanguage: '',
		entries: { ...EMPTY_DICTIONARY_ENTRIES }
	};
}

async function fetchCanonicalDictionariesPayload(
	api: ApiClient,
	indexName: string,
	requestedDictionaryRaw: string | null,
	requestedLanguageRaw: string | null,
	options: { reportLanguagesError?: boolean; captureSessionFailure?: boolean } = {}
): Promise<CanonicalDictionariesPayloadResult> {
	const requestedDictionary = resolveDictionaryName(requestedDictionaryRaw);
	const requestedLanguage = requestedLanguageRaw?.trim() ?? '';

	let languages: DictionaryLanguagesResponse | null = null;
	let languagesError: string | null = null;
	try {
		languages = await api.getDictionaryLanguages(indexName);
	} catch (error) {
		if (options.captureSessionFailure) {
			const sessionFailure = mapDashboardSessionFailure(error);
			if (sessionFailure) {
				return {
					payload: {
						languages: null,
						selectedDictionary: requestedDictionary,
						selectedLanguage: requestedLanguage,
						entries: { ...EMPTY_DICTIONARY_ENTRIES }
					},
					requestError: null,
					sessionFailure
				};
			}
		}
		languagesError = errorMessage(error, 'Failed to browse dictionary entries');
	}

	if (!languages) {
		return {
			payload: {
				languages: null,
				selectedDictionary: requestedDictionary,
				selectedLanguage: requestedLanguage,
				entries: { ...EMPTY_DICTIONARY_ENTRIES }
			},
			requestError: options.reportLanguagesError ? languagesError : null,
			sessionFailure: null
		};
	}

	const { selectedDictionary, selectedLanguage } = resolveDictionarySelection(
		languages,
		requestedDictionaryRaw,
		requestedLanguageRaw
	);

	if (!selectedLanguage) {
		return {
			payload: {
				languages,
				selectedDictionary,
				selectedLanguage,
				entries: { ...EMPTY_DICTIONARY_ENTRIES }
			},
			requestError: null,
			sessionFailure: null
		};
	}

	try {
		const entries = await api.searchDictionaryEntries(indexName, selectedDictionary, {
			query: '',
			language: selectedLanguage
		});

		return {
			payload: {
				languages,
				selectedDictionary,
				selectedLanguage,
				entries
			},
			requestError: null,
			sessionFailure: null
		};
	} catch (error) {
		if (options.captureSessionFailure) {
			const sessionFailure = mapDashboardSessionFailure(error);
			if (sessionFailure) {
				return {
					payload: {
						languages,
						selectedDictionary,
						selectedLanguage,
						entries: { ...EMPTY_DICTIONARY_ENTRIES }
					},
					requestError: null,
					sessionFailure
				};
			}
		}

		return {
			payload: {
				languages,
				selectedDictionary,
				selectedLanguage,
				entries: { ...EMPTY_DICTIONARY_ENTRIES }
			},
			requestError: errorMessage(error, 'Failed to browse dictionary entries'),
			sessionFailure: null
		};
	}
}

export async function loadDictionariesPayload(
	api: ApiClient,
	indexName: string,
	requestedDictionaryRaw: string | null,
	requestedLanguageRaw: string | null
): Promise<DictionariesPayload> {
	const { payload } = await fetchCanonicalDictionariesPayload(
		api,
		indexName,
		requestedDictionaryRaw,
		requestedLanguageRaw
	);

	return payload;
}

export async function browseDictionaryEntriesAction({
	request,
	indexName,
	token
}: DictionaryActionArgs) {
	const data = await request.formData();

	let selection: { dictionary: DictionaryName; language: string };
	try {
		selection = parseDictionarySelectionFromForm(data);
	} catch (error) {
		return fail(400, {
			dictionaryBrowseError: errorMessage(error, 'Invalid dictionary browse selection'),
			dictionaries: emptyDictionariesPayload()
		});
	}

	const api = createApiClient(token);
	const { payload, requestError, sessionFailure } = await fetchCanonicalDictionariesPayload(
		api,
		indexName,
		selection.dictionary,
		selection.language,
		{ reportLanguagesError: true, captureSessionFailure: true }
	);
	if (sessionFailure) return sessionFailure;
	if (requestError) {
		return fail(400, {
			dictionaryBrowseError: requestError,
			dictionaries: payload
		});
	}

	return { dictionaries: payload };
}

export async function saveDictionaryEntryAction({
	request,
	indexName,
	token
}: DictionaryActionArgs) {
	const data = await request.formData();

	let selection: { dictionary: DictionaryName; language: string };
	try {
		selection = parseDictionarySelectionFromForm(data);
	} catch (error) {
		return fail(400, {
			dictionarySaveError: errorMessage(error, 'Invalid dictionary selection'),
			dictionaries: emptyDictionariesPayload()
		});
	}

	let entryBody: Record<string, unknown>;
	try {
		entryBody = parseDictionaryEntryFromForm(data, selection);
	} catch (error) {
		const api = createApiClient(token);
		const { payload, sessionFailure } = await fetchCanonicalDictionariesPayload(
			api,
			indexName,
			selection.dictionary,
			selection.language,
			{ captureSessionFailure: true }
		);
		if (sessionFailure) return sessionFailure;
		return fail(400, {
			dictionarySaveError: errorMessage(error, 'Invalid dictionary entry fields'),
			dictionaries: payload
		});
	}

	const batchRequest: DictionaryBatchRequest = {
		clearExistingDictionaryEntries: false,
		requests: [{ action: 'addEntry', body: entryBody }]
	};

	const api = createApiClient(token);
	try {
		await api.batchDictionaryEntries(indexName, selection.dictionary, batchRequest);
	} catch (error) {
		const sessionFailure = mapDashboardSessionFailure(error);
		if (sessionFailure) return sessionFailure;

		const { payload, sessionFailure: refreshSessionFailure } =
			await fetchCanonicalDictionariesPayload(
				api,
				indexName,
				selection.dictionary,
				selection.language,
				{ captureSessionFailure: true }
			);
		if (refreshSessionFailure) return refreshSessionFailure;
		return fail(400, {
			dictionarySaveError: errorMessage(error, 'Failed to save dictionary entry'),
			dictionaries: payload
		});
	}

	const { payload, requestError, sessionFailure } = await fetchCanonicalDictionariesPayload(
		api,
		indexName,
		selection.dictionary,
		selection.language,
		{ reportLanguagesError: true, captureSessionFailure: true }
	);
	if (sessionFailure) return sessionFailure;
	if (requestError) {
		return fail(400, {
			dictionarySaveError: requestError,
			dictionaries: payload
		});
	}

	return {
		dictionarySaved: true,
		dictionaries: payload
	};
}

export async function deleteDictionaryEntryAction({
	request,
	indexName,
	token
}: DictionaryActionArgs) {
	const data = await request.formData();

	let selection: { dictionary: DictionaryName; language: string };
	try {
		selection = parseDictionarySelectionFromForm(data);
	} catch (error) {
		return fail(400, {
			dictionaryDeleteError: errorMessage(error, 'Invalid dictionary selection'),
			dictionaries: emptyDictionariesPayload()
		});
	}

	const objectID = (data.get('objectID') as string | null)?.trim();
	if (!objectID) {
		const api = createApiClient(token);
		const { payload, sessionFailure } = await fetchCanonicalDictionariesPayload(
			api,
			indexName,
			selection.dictionary,
			selection.language,
			{ captureSessionFailure: true }
		);
		if (sessionFailure) return sessionFailure;
		return fail(400, {
			dictionaryDeleteError: 'objectID is required',
			dictionaries: payload
		});
	}

	const batchRequest: DictionaryBatchRequest = {
		clearExistingDictionaryEntries: false,
		requests: [{ action: 'deleteEntry', body: { objectID } }]
	};

	const api = createApiClient(token);
	try {
		await api.batchDictionaryEntries(indexName, selection.dictionary, batchRequest);
	} catch (error) {
		const sessionFailure = mapDashboardSessionFailure(error);
		if (sessionFailure) return sessionFailure;

		const { payload, sessionFailure: refreshSessionFailure } =
			await fetchCanonicalDictionariesPayload(
				api,
				indexName,
				selection.dictionary,
				selection.language,
				{ captureSessionFailure: true }
			);
		if (refreshSessionFailure) return refreshSessionFailure;
		return fail(400, {
			dictionaryDeleteError: errorMessage(error, 'Failed to delete dictionary entry'),
			dictionaries: payload
		});
	}

	const { payload, requestError, sessionFailure } = await fetchCanonicalDictionariesPayload(
		api,
		indexName,
		selection.dictionary,
		selection.language,
		{ reportLanguagesError: true, captureSessionFailure: true }
	);
	if (sessionFailure) return sessionFailure;
	if (requestError) {
		return fail(400, {
			dictionaryDeleteError: requestError,
			dictionaries: payload
		});
	}

	return {
		dictionaryDeleted: true,
		dictionaries: payload
	};
}
