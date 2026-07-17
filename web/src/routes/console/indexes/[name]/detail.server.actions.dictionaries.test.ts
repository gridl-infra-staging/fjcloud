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

const { apiClientFactoryForMock, mocks } = await vi.hoisted(async () => {
	const shared = await import('./detail.server.test.shared');
	return {
		apiClientFactoryForMock: shared.apiClientFactoryFor,
		mocks: shared.createMockFns(vi.fn)
	};
});
const {
	getDictionaryLanguages: getDictionaryLanguagesMock,
	searchDictionaryEntries: searchDictionaryEntriesMock,
	batchDictionaryEntries: batchDictionaryEntriesMock
} = mocks;

// ---------------------------------------------------------------------------
// vi.mock (top-level, as required by vitest)
// ---------------------------------------------------------------------------

vi.mock('$lib/server/api', () => apiClientFactoryForMock(mocks, vi.fn));

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
		formData.set('entryWord', 'the');
		formData.set('intent', 'add');

		const randomUuidSpy = vi
			.spyOn(globalThis.crypto, 'randomUUID')
			.mockReturnValue('00000000-0000-4000-8000-000000000001');
		const result = await actions.saveDictionaryEntry(
			makeActionArgs('saveDictionaryEntry', formData) as never
		);
		randomUuidSpy.mockRestore();

		expect(batchDictionaryEntriesMock).toHaveBeenCalledWith('products', 'stopwords', {
			clearExistingDictionaryEntries: false,
			requests: [
				{
					action: 'addEntry',
					body: {
						objectID: '00000000-0000-4000-8000-000000000001',
						language: 'en',
						word: 'the',
						state: 'enabled'
					}
				}
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

	it('saveDictionaryEntry action preserves submitted stopword state in batch payload', async () => {
		batchDictionaryEntriesMock.mockResolvedValue({ taskID: 42, updatedAt: '2026-03-18T12:00:00Z' });
		getDictionaryLanguagesMock.mockResolvedValue({
			en: { stopwords: { nbCustomEntries: 1 }, plurals: null, compounds: null }
		});
		searchDictionaryEntriesMock.mockResolvedValue({
			hits: [{ objectID: 'stop-the', language: 'en', word: 'the', state: 'disabled' }],
			nbHits: 1,
			page: 0,
			nbPages: 1
		});

		const formData = new FormData();
		formData.set('dictionary', 'stopwords');
		formData.set('language', 'en');
		formData.set('objectID', 'stop-the');
		formData.set('entryWord', 'the');
		formData.set('state', 'disabled');

		await actions.saveDictionaryEntry(makeActionArgs('saveDictionaryEntry', formData) as never);

		expect(batchDictionaryEntriesMock).toHaveBeenCalledWith('products', 'stopwords', {
			clearExistingDictionaryEntries: false,
			requests: [
				{
					action: 'addEntry',
					body: { objectID: 'stop-the', language: 'en', word: 'the', state: 'disabled' }
				}
			]
		});
	});

	it('saveDictionaryEntry action preserves submitted objectID when editing an existing entry', async () => {
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
		formData.set('intent', 'edit');
		formData.set('objectID', 'stop-the');
		formData.set('entryWord', 'the');

		const randomUuidSpy = vi.spyOn(globalThis.crypto, 'randomUUID');
		await actions.saveDictionaryEntry(makeActionArgs('saveDictionaryEntry', formData) as never);
		randomUuidSpy.mockRestore();

		expect(randomUuidSpy).not.toHaveBeenCalled();
		expect(batchDictionaryEntriesMock).toHaveBeenCalledWith('products', 'stopwords', {
			clearExistingDictionaryEntries: false,
			requests: [
				{
					action: 'addEntry',
					body: { objectID: 'stop-the', language: 'en', word: 'the', state: 'enabled' }
				}
			]
		});
	});

	it('saveDictionaryEntry action accepts a one-word plurals payload', async () => {
		batchDictionaryEntriesMock.mockResolvedValue({ taskID: 42, updatedAt: '2026-03-18T12:00:00Z' });
		getDictionaryLanguagesMock.mockResolvedValue({
			en: { stopwords: null, plurals: { nbCustomEntries: 1 }, compounds: null }
		});
		searchDictionaryEntriesMock.mockResolvedValue({
			hits: [{ objectID: 'plural-sheep', language: 'en', words: ['sheep'] }],
			nbHits: 1,
			page: 0,
			nbPages: 1
		});

		const formData = new FormData();
		formData.set('dictionary', 'plurals');
		formData.set('language', 'en');
		formData.set('objectID', 'plural-sheep');
		formData.set('entryWords', 'sheep');

		const result = await actions.saveDictionaryEntry(
			makeActionArgs('saveDictionaryEntry', formData) as never
		);

		expect(batchDictionaryEntriesMock).toHaveBeenCalledWith('products', 'plurals', {
			clearExistingDictionaryEntries: false,
			requests: [
				{
					action: 'addEntry',
					body: { objectID: 'plural-sheep', language: 'en', words: ['sheep'] }
				}
			]
		});
		expect(result).toEqual({
			dictionarySaved: true,
			dictionaries: {
				languages: {
					en: { stopwords: null, plurals: { nbCustomEntries: 1 }, compounds: null }
				},
				selectedDictionary: 'plurals',
				selectedLanguage: 'en',
				entries: {
					hits: [{ objectID: 'plural-sheep', language: 'en', words: ['sheep'] }],
					nbHits: 1,
					page: 0,
					nbPages: 1
				}
			}
		});
	});

	it('saveDictionaryEntry action rejects unexpected stopword state values', async () => {
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
		formData.set('state', 'archived');

		const result = await actions.saveDictionaryEntry(
			makeActionArgs('saveDictionaryEntry', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					dictionarySaveError: expect.stringContaining('state must be enabled or disabled')
				})
			})
		);
		expect(batchDictionaryEntriesMock).not.toHaveBeenCalled();
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

	it('saveDictionaryEntry action rejects missing objectID for edit intent', async () => {
		const formData = new FormData();
		formData.set('dictionary', 'stopwords');
		formData.set('language', 'en');
		formData.set('entryWord', 'the');
		formData.set('intent', 'edit');

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

	it('clearDictionaryEntries action clears all entries via batch clear payload', async () => {
		batchDictionaryEntriesMock.mockResolvedValue({ taskID: 44, updatedAt: '2026-03-18T12:00:00Z' });
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

		const result = await actions.clearDictionaryEntries(
			makeActionArgs('clearDictionaryEntries', formData) as never
		);

		expect(batchDictionaryEntriesMock).toHaveBeenCalledWith('products', 'stopwords', {
			clearExistingDictionaryEntries: true,
			requests: []
		});
		expect(result).toEqual({
			dictionaryCleared: true,
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
});
