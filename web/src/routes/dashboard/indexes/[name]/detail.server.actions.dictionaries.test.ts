import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import {
	EMPTY_DICTIONARIES,
	EMPTY_DICTIONARY_ENTRIES,
	makeActionArgs
} from './detail.server.test.shared';

// ---------------------------------------------------------------------------
// Mock function references (must be declared before vi.mock)
// ---------------------------------------------------------------------------

const getIndexMock = vi.fn();
const getIndexSettingsMock = vi.fn();
const listReplicasMock = vi.fn();
const getInternalRegionsMock = vi.fn();
const addObjectsMock = vi.fn();
const browseObjectsMock = vi.fn();
const deleteObjectMock = vi.fn();
const searchRulesMock = vi.fn();
const searchSynonymsMock = vi.fn();
const getPersonalizationStrategyMock = vi.fn();
const getQsConfigMock = vi.fn();
const getQsStatusMock = vi.fn();
const getAnalyticsTopSearchesMock = vi.fn();
const getAnalyticsSearchCountMock = vi.fn();
const getAnalyticsNoResultsMock = vi.fn();
const getAnalyticsNoResultRateMock = vi.fn();
const getAnalyticsStatusMock = vi.fn();
const getDebugEventsMock = vi.fn();
const listExperimentsMock = vi.fn();
const createExperimentMock = vi.fn();
const deleteExperimentMock = vi.fn();
const startExperimentMock = vi.fn();
const stopExperimentMock = vi.fn();
const concludeExperimentMock = vi.fn();
const getExperimentResultsMock = vi.fn();
const updateIndexSettingsMock = vi.fn();
const saveRuleMock = vi.fn();
const deleteRuleMock = vi.fn();
const saveSynonymMock = vi.fn();
const deleteSynonymMock = vi.fn();
const saveQsConfigMock = vi.fn();
const deleteQsConfigMock = vi.fn();
const createIndexKeyMock = vi.fn();
const getDictionaryLanguagesMock = vi.fn();
const searchDictionaryEntriesMock = vi.fn();
const batchDictionaryEntriesMock = vi.fn();
const getSecuritySourcesMock = vi.fn();
const appendSecuritySourceMock = vi.fn();
const deleteSecuritySourceMock = vi.fn();

// ---------------------------------------------------------------------------
// vi.mock (top-level, as required by vitest)
// ---------------------------------------------------------------------------

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		getIndex: getIndexMock,
		getIndexSettings: getIndexSettingsMock,
		listReplicas: listReplicasMock,
		getInternalRegions: getInternalRegionsMock,
		addObjects: addObjectsMock,
		browseObjects: browseObjectsMock,
		deleteObject: deleteObjectMock,
		searchRules: searchRulesMock,
		searchSynonyms: searchSynonymsMock,
		getPersonalizationStrategy: getPersonalizationStrategyMock,
		savePersonalizationStrategy: vi.fn(),
		deletePersonalizationStrategy: vi.fn(),
		getPersonalizationProfile: vi.fn(),
		deletePersonalizationProfile: vi.fn(),
		recommend: vi.fn(),
		chat: vi.fn(),
		getQsConfig: getQsConfigMock,
		getQsStatus: getQsStatusMock,
		getAnalyticsTopSearches: getAnalyticsTopSearchesMock,
		getAnalyticsSearchCount: getAnalyticsSearchCountMock,
		getAnalyticsNoResults: getAnalyticsNoResultsMock,
		getAnalyticsNoResultRate: getAnalyticsNoResultRateMock,
		getAnalyticsStatus: getAnalyticsStatusMock,
		getDebugEvents: getDebugEventsMock,
		listExperiments: listExperimentsMock,
		createExperiment: createExperimentMock,
		deleteExperiment: deleteExperimentMock,
		startExperiment: startExperimentMock,
		stopExperiment: stopExperimentMock,
		concludeExperiment: concludeExperimentMock,
		getExperimentResults: getExperimentResultsMock,
		updateIndexSettings: updateIndexSettingsMock,
		saveRule: saveRuleMock,
		deleteRule: deleteRuleMock,
		saveSynonym: saveSynonymMock,
		deleteSynonym: deleteSynonymMock,
		saveQsConfig: saveQsConfigMock,
		deleteQsConfig: deleteQsConfigMock,
		createIndexKey: createIndexKeyMock,
		getDictionaryLanguages: getDictionaryLanguagesMock,
		searchDictionaryEntries: searchDictionaryEntriesMock,
		batchDictionaryEntries: batchDictionaryEntriesMock,
		getSecuritySources: getSecuritySourcesMock,
		appendSecuritySource: appendSecuritySourceMock,
		deleteSecuritySource: deleteSecuritySourceMock
	}))
}));

// ---------------------------------------------------------------------------
// Module under test (imported AFTER vi.mock)
// ---------------------------------------------------------------------------

import { actions } from './+page.server';

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('Index detail page server -- actions (dictionaries)', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	// Dictionary actions
	// ---------------------------------------------------------------------------

	it('browseDictionaryEntries action searches entries and returns canonical dictionaries payload', async () => {
		getDictionaryLanguagesMock.mockResolvedValue({
			en: { stopwords: { nbCustomEntries: 2 }, plurals: null, compounds: null },
			fr: { stopwords: { nbCustomEntries: 1 }, plurals: null, compounds: null }
		});
		searchDictionaryEntriesMock.mockResolvedValue({
			hits: [{ objectID: 'stop-the', language: 'en', word: 'the', state: 'enabled' }],
			nbHits: 1,
			page: 0,
			nbPages: 1
		});

		const formData = new FormData();
		formData.set('dictionary', 'stopwords');
		formData.set('language', 'en');

		const result = await actions.browseDictionaryEntries(
			makeActionArgs('browseDictionaryEntries', formData) as never
		);

		expect(searchDictionaryEntriesMock).toHaveBeenCalledWith('products', 'stopwords', {
			query: '',
			language: 'en'
		});
		expect(getDictionaryLanguagesMock).toHaveBeenCalledWith('products');
		expect(result).toEqual({
			dictionaries: {
				languages: {
					en: { stopwords: { nbCustomEntries: 2 }, plurals: null, compounds: null },
					fr: { stopwords: { nbCustomEntries: 1 }, plurals: null, compounds: null }
				},
				selectedDictionary: 'stopwords',
				selectedLanguage: 'en',
				entries: {
					hits: [{ objectID: 'stop-the', language: 'en', word: 'the', state: 'enabled' }],
					nbHits: 1,
					page: 0,
					nbPages: 1
				}
			}
		});
	});

	it('browseDictionaryEntries action preserves an existing language when the selected dictionary is empty', async () => {
		getDictionaryLanguagesMock.mockResolvedValue({
			en: { stopwords: { nbCustomEntries: 2 }, plurals: null, compounds: null },
			fr: { stopwords: null, plurals: { nbCustomEntries: 1 }, compounds: null }
		});
		searchDictionaryEntriesMock.mockResolvedValue({
			hits: [],
			nbHits: 0,
			page: 0,
			nbPages: 0
		});

		const formData = new FormData();
		formData.set('dictionary', 'plurals');
		formData.set('language', 'en');

		const result = await actions.browseDictionaryEntries(
			makeActionArgs('browseDictionaryEntries', formData) as never
		);

		expect(searchDictionaryEntriesMock).toHaveBeenCalledWith('products', 'plurals', {
			query: '',
			language: 'en'
		});
		expect(result).toEqual({
			dictionaries: {
				languages: {
					en: { stopwords: { nbCustomEntries: 2 }, plurals: null, compounds: null },
					fr: { stopwords: null, plurals: { nbCustomEntries: 1 }, compounds: null }
				},
				selectedDictionary: 'plurals',
				selectedLanguage: 'en',
				entries: {
					hits: [],
					nbHits: 0,
					page: 0,
					nbPages: 0
				}
			}
		});
	});

	it('browseDictionaryEntries action returns shared session failure for 403 dictionary auth errors', async () => {
		getDictionaryLanguagesMock.mockRejectedValue(new ApiRequestError(403, 'Forbidden'));

		const formData = new FormData();
		formData.set('dictionary', 'stopwords');
		formData.set('language', 'en');

		const result = await actions.browseDictionaryEntries(
			makeActionArgs('browseDictionaryEntries', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 403,
				data: expect.objectContaining({
					_authSessionExpired: true,
					error: 'Forbidden'
				})
			})
		);
		expect(searchDictionaryEntriesMock).not.toHaveBeenCalled();
	});

	it('browseDictionaryEntries action preserves a typed language when no dictionary languages exist yet', async () => {
		getDictionaryLanguagesMock.mockResolvedValue({});
		searchDictionaryEntriesMock.mockResolvedValue({
			hits: [],
			nbHits: 0,
			page: 0,
			nbPages: 0
		});

		const formData = new FormData();
		formData.set('dictionary', 'stopwords');
		formData.set('language', 'en');

		const result = await actions.browseDictionaryEntries(
			makeActionArgs('browseDictionaryEntries', formData) as never
		);

		expect(searchDictionaryEntriesMock).toHaveBeenCalledWith('products', 'stopwords', {
			query: '',
			language: 'en'
		});
		expect(result).toEqual({
			dictionaries: {
				languages: {},
				selectedDictionary: 'stopwords',
				selectedLanguage: 'en',
				entries: {
					hits: [],
					nbHits: 0,
					page: 0,
					nbPages: 0
				}
			}
		});
	});

	it('browseDictionaryEntries action falls back to empty entries on search failure', async () => {
		getDictionaryLanguagesMock.mockResolvedValue({
			en: { stopwords: { nbCustomEntries: 1 }, plurals: null, compounds: null }
		});
		searchDictionaryEntriesMock.mockRejectedValue(new Error('search failed'));

		const formData = new FormData();
		formData.set('dictionary', 'stopwords');
		formData.set('language', 'en');

		const result = await actions.browseDictionaryEntries(
			makeActionArgs('browseDictionaryEntries', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					dictionaryBrowseError: 'search failed',
					dictionaries: expect.objectContaining({
						selectedDictionary: 'stopwords',
						selectedLanguage: 'en',
						entries: { ...EMPTY_DICTIONARY_ENTRIES }
					})
				})
			})
		);
	});

	it('browseDictionaryEntries action rejects invalid dictionary name with fail(400)', async () => {
		const formData = new FormData();
		formData.set('dictionary', 'badname');
		formData.set('language', 'en');

		const result = await actions.browseDictionaryEntries(
			makeActionArgs('browseDictionaryEntries', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					dictionaryBrowseError: expect.stringContaining('Invalid dictionary')
				})
			})
		);
		expect(searchDictionaryEntriesMock).not.toHaveBeenCalled();
	});

	it('browseDictionaryEntries action rejects missing dictionary selector with fail(400)', async () => {
		const formData = new FormData();
		formData.set('language', 'en');

		const result = await actions.browseDictionaryEntries(
			makeActionArgs('browseDictionaryEntries', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					dictionaryBrowseError: 'dictionary is required',
					dictionaries: { ...EMPTY_DICTIONARIES }
				})
			})
		);
		expect(getDictionaryLanguagesMock).not.toHaveBeenCalled();
		expect(searchDictionaryEntriesMock).not.toHaveBeenCalled();
	});

	it('browseDictionaryEntries action rejects missing language selector with fail(400)', async () => {
		const formData = new FormData();
		formData.set('dictionary', 'stopwords');

		const result = await actions.browseDictionaryEntries(
			makeActionArgs('browseDictionaryEntries', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					dictionaryBrowseError: 'language is required',
					dictionaries: { ...EMPTY_DICTIONARIES }
				})
			})
		);
		expect(getDictionaryLanguagesMock).not.toHaveBeenCalled();
		expect(searchDictionaryEntriesMock).not.toHaveBeenCalled();
	});

	it('browseDictionaryEntries action surfaces dictionary languages fetch failures', async () => {
		getDictionaryLanguagesMock.mockRejectedValue(new Error('languages unavailable'));

		const formData = new FormData();
		formData.set('dictionary', 'stopwords');
		formData.set('language', 'en');

		const result = await actions.browseDictionaryEntries(
			makeActionArgs('browseDictionaryEntries', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					dictionaryBrowseError: 'languages unavailable',
					dictionaries: expect.objectContaining({
						languages: null,
						selectedDictionary: 'stopwords',
						selectedLanguage: 'en',
						entries: { ...EMPTY_DICTIONARY_ENTRIES }
					})
				})
			})
		);
		expect(searchDictionaryEntriesMock).not.toHaveBeenCalled();
	});

	it('saveDictionaryEntry action batches addEntry and returns refreshed dictionaries payload', async () => {
		batchDictionaryEntriesMock.mockResolvedValue({ taskID: 42, updatedAt: '2026-03-18T12:00:00Z' });
		getDictionaryLanguagesMock.mockResolvedValue({
			en: { stopwords: { nbCustomEntries: 1 }, plurals: null, compounds: null }
		});
		searchDictionaryEntriesMock.mockResolvedValue({
			hits: [{ objectID: 'stop-the', language: 'en', word: 'the', state: 'enabled' }],
			nbHits: 1,
			page: 0,
			nbPages: 1
		});

		const formData = new FormData();
		formData.set('dictionary', 'stopwords');
		formData.set('language', 'en');
		formData.set('objectID', 'stop-the');
		formData.set('entryWord', 'the');

		const result = await actions.saveDictionaryEntry(
			makeActionArgs('saveDictionaryEntry', formData) as never
		);

		expect(batchDictionaryEntriesMock).toHaveBeenCalledWith('products', 'stopwords', {
			clearExistingDictionaryEntries: false,
			requests: [
				{ action: 'addEntry', body: { objectID: 'stop-the', language: 'en', word: 'the' } }
			]
		});
		expect(searchDictionaryEntriesMock).toHaveBeenCalledWith('products', 'stopwords', {
			query: '',
			language: 'en'
		});
		expect(result).toEqual({
			dictionarySaved: true,
			dictionaries: {
				languages: {
					en: { stopwords: { nbCustomEntries: 1 }, plurals: null, compounds: null }
				},
				selectedDictionary: 'stopwords',
				selectedLanguage: 'en',
				entries: {
					hits: [{ objectID: 'stop-the', language: 'en', word: 'the', state: 'enabled' }],
					nbHits: 1,
					page: 0,
					nbPages: 1
				}
			}
		});
	});

	it('saveDictionaryEntry action rejects missing dictionary selector with fail(400)', async () => {
		const formData = new FormData();
		formData.set('language', 'en');
		formData.set('objectID', 'stop-the');
		formData.set('entryWord', 'the');

		const result = await actions.saveDictionaryEntry(
			makeActionArgs('saveDictionaryEntry', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					dictionarySaveError: 'dictionary is required',
					dictionaries: { ...EMPTY_DICTIONARIES }
				})
			})
		);
		expect(batchDictionaryEntriesMock).not.toHaveBeenCalled();
	});

	it('saveDictionaryEntry action rejects missing language selector with fail(400)', async () => {
		const formData = new FormData();
		formData.set('dictionary', 'stopwords');
		formData.set('objectID', 'stop-the');
		formData.set('entryWord', 'the');

		const result = await actions.saveDictionaryEntry(
			makeActionArgs('saveDictionaryEntry', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					dictionarySaveError: 'language is required',
					dictionaries: { ...EMPTY_DICTIONARIES }
				})
			})
		);
		expect(batchDictionaryEntriesMock).not.toHaveBeenCalled();
	});

	it('saveDictionaryEntry action rejects missing objectID with fail(400)', async () => {
		const formData = new FormData();
		formData.set('dictionary', 'stopwords');
		formData.set('language', 'en');
		formData.set('entryWord', 'the');

		const result = await actions.saveDictionaryEntry(
			makeActionArgs('saveDictionaryEntry', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					dictionarySaveError: 'objectID is required'
				})
			})
		);
		expect(batchDictionaryEntriesMock).not.toHaveBeenCalled();
	});

	it('saveDictionaryEntry action rejects missing word for stopwords with fail(400)', async () => {
		getDictionaryLanguagesMock.mockResolvedValue({
			en: { stopwords: { nbCustomEntries: 1 }, plurals: null, compounds: null }
		});
		searchDictionaryEntriesMock.mockResolvedValue({
			hits: [{ objectID: 'stop-the', language: 'en', word: 'the', state: 'enabled' }],
			nbHits: 1,
			page: 0,
			nbPages: 1
		});

		const formData = new FormData();
		formData.set('dictionary', 'stopwords');
		formData.set('language', 'en');
		formData.set('objectID', 'stop-the');

		const result = await actions.saveDictionaryEntry(
			makeActionArgs('saveDictionaryEntry', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					dictionarySaveError: 'entryWord is required for stopwords',
					dictionaries: {
						languages: {
							en: { stopwords: { nbCustomEntries: 1 }, plurals: null, compounds: null }
						},
						selectedDictionary: 'stopwords',
						selectedLanguage: 'en',
						entries: {
							hits: [{ objectID: 'stop-the', language: 'en', word: 'the', state: 'enabled' }],
							nbHits: 1,
							page: 0,
							nbPages: 1
						}
					}
				})
			})
		);
		expect(batchDictionaryEntriesMock).not.toHaveBeenCalled();
	});

	it('saveDictionaryEntry action fails when refreshed dictionary payload cannot be loaded', async () => {
		batchDictionaryEntriesMock.mockResolvedValue({ taskID: 42, updatedAt: '2026-03-18T12:00:00Z' });
		getDictionaryLanguagesMock.mockRejectedValue(new Error('languages unavailable'));

		const formData = new FormData();
		formData.set('dictionary', 'stopwords');
		formData.set('language', 'en');
		formData.set('objectID', 'stop-the');
		formData.set('entryWord', 'the');

		const result = await actions.saveDictionaryEntry(
			makeActionArgs('saveDictionaryEntry', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					dictionarySaveError: 'languages unavailable',
					dictionaries: expect.objectContaining({
						languages: null,
						selectedDictionary: 'stopwords',
						selectedLanguage: 'en',
						entries: { ...EMPTY_DICTIONARY_ENTRIES }
					})
				})
			})
		);
		expect(searchDictionaryEntriesMock).not.toHaveBeenCalled();
	});

	it('deleteDictionaryEntry action batches deleteEntry and returns refreshed dictionaries payload', async () => {
		batchDictionaryEntriesMock.mockResolvedValue({ taskID: 43, updatedAt: '2026-03-18T12:00:00Z' });
		getDictionaryLanguagesMock.mockResolvedValue({
			en: { stopwords: { nbCustomEntries: 0 }, plurals: null, compounds: null }
		});
		searchDictionaryEntriesMock.mockResolvedValue({
			hits: [],
			nbHits: 0,
			page: 0,
			nbPages: 0
		});

		const formData = new FormData();
		formData.set('dictionary', 'stopwords');
		formData.set('language', 'en');
		formData.set('objectID', 'stop-the');

		const result = await actions.deleteDictionaryEntry(
			makeActionArgs('deleteDictionaryEntry', formData) as never
		);

		expect(batchDictionaryEntriesMock).toHaveBeenCalledWith('products', 'stopwords', {
			clearExistingDictionaryEntries: false,
			requests: [{ action: 'deleteEntry', body: { objectID: 'stop-the' } }]
		});
		expect(searchDictionaryEntriesMock).toHaveBeenCalledWith('products', 'stopwords', {
			query: '',
			language: 'en'
		});
		expect(result).toEqual({
			dictionaryDeleted: true,
			dictionaries: {
				languages: {
					en: { stopwords: { nbCustomEntries: 0 }, plurals: null, compounds: null }
				},
				selectedDictionary: 'stopwords',
				selectedLanguage: 'en',
				entries: {
					hits: [],
					nbHits: 0,
					page: 0,
					nbPages: 0
				}
			}
		});
	});

	it('deleteDictionaryEntry action rejects missing dictionary selector with fail(400)', async () => {
		const formData = new FormData();
		formData.set('language', 'en');
		formData.set('objectID', 'stop-the');

		const result = await actions.deleteDictionaryEntry(
			makeActionArgs('deleteDictionaryEntry', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					dictionaryDeleteError: 'dictionary is required',
					dictionaries: { ...EMPTY_DICTIONARIES }
				})
			})
		);
		expect(batchDictionaryEntriesMock).not.toHaveBeenCalled();
	});

	it('deleteDictionaryEntry action rejects missing language selector with fail(400)', async () => {
		const formData = new FormData();
		formData.set('dictionary', 'stopwords');
		formData.set('objectID', 'stop-the');

		const result = await actions.deleteDictionaryEntry(
			makeActionArgs('deleteDictionaryEntry', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					dictionaryDeleteError: 'language is required',
					dictionaries: { ...EMPTY_DICTIONARIES }
				})
			})
		);
		expect(batchDictionaryEntriesMock).not.toHaveBeenCalled();
	});

	it('deleteDictionaryEntry action rejects missing objectID with fail(400)', async () => {
		getDictionaryLanguagesMock.mockResolvedValue({
			en: { stopwords: { nbCustomEntries: 1 }, plurals: null, compounds: null }
		});
		searchDictionaryEntriesMock.mockResolvedValue({
			hits: [{ objectID: 'stop-the', language: 'en', word: 'the', state: 'enabled' }],
			nbHits: 1,
			page: 0,
			nbPages: 1
		});

		const formData = new FormData();
		formData.set('dictionary', 'stopwords');
		formData.set('language', 'en');

		const result = await actions.deleteDictionaryEntry(
			makeActionArgs('deleteDictionaryEntry', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					dictionaryDeleteError: 'objectID is required',
					dictionaries: {
						languages: {
							en: { stopwords: { nbCustomEntries: 1 }, plurals: null, compounds: null }
						},
						selectedDictionary: 'stopwords',
						selectedLanguage: 'en',
						entries: {
							hits: [{ objectID: 'stop-the', language: 'en', word: 'the', state: 'enabled' }],
							nbHits: 1,
							page: 0,
							nbPages: 1
						}
					}
				})
			})
		);
		expect(batchDictionaryEntriesMock).not.toHaveBeenCalled();
	});
});
