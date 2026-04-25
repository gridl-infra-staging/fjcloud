import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import { EMPTY_DOCUMENTS, makeActionArgs } from './detail.server.test.shared';

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

describe('Index detail page server -- actions (documents)', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('uploadDocuments action forwards normalized batch payload and returns refreshed browse data', async () => {
		addObjectsMock.mockResolvedValue({ taskID: 99, objectIDs: ['obj-1'] });
		browseObjectsMock.mockResolvedValue({
			hits: [{ objectID: 'obj-1', title: 'First' }],
			cursor: null,
			nbHits: 1,
			page: 0,
			nbPages: 1,
			hitsPerPage: 20,
			query: 'title:First',
			params: ''
		});

		const formData = new FormData();
		formData.set(
			'batch',
			JSON.stringify({
				requests: [{ action: 'addObject', body: { objectID: 'obj-1', title: 'First' } }]
			})
		);
		formData.set('query', 'title:First');
		formData.set('hitsPerPage', '20');

		const result = await actions.uploadDocuments(
			makeActionArgs('uploadDocuments', formData) as never
		);

		expect(addObjectsMock).toHaveBeenCalledWith('products', {
			requests: [{ action: 'addObject', body: { objectID: 'obj-1', title: 'First' } }]
		});
		expect(browseObjectsMock).toHaveBeenCalledWith('products', {
			query: 'title:First',
			hitsPerPage: 20
		});
		expect(result).toEqual({
			documentsUploadSuccess: true,
			documents: {
				hits: [{ objectID: 'obj-1', title: 'First' }],
				cursor: null,
				nbHits: 1,
				page: 0,
				nbPages: 1,
				hitsPerPage: 20,
				query: 'title:First',
				params: ''
			}
		});
	});

	it('uploadDocuments action rejects invalid JSON payload with fail(400)', async () => {
		const formData = new FormData();
		formData.set('batch', '{');

		const result = await actions.uploadDocuments(
			makeActionArgs('uploadDocuments', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					documentsUploadError: 'batch must be valid JSON'
				})
			})
		);
		expect(addObjectsMock).not.toHaveBeenCalled();
	});

	it('uploadDocuments action rejects empty requests array with fail(400)', async () => {
		const formData = new FormData();
		formData.set('batch', JSON.stringify({ requests: [] }));

		const result = await actions.uploadDocuments(
			makeActionArgs('uploadDocuments', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					documentsUploadError: 'batch must include at least one request'
				})
			})
		);
		expect(addObjectsMock).not.toHaveBeenCalled();
	});

	it('uploadDocuments action returns fail(400) when addObjects request fails', async () => {
		addObjectsMock.mockRejectedValue(new Error('upstream failed'));
		const formData = new FormData();
		formData.set(
			'batch',
			JSON.stringify({
				requests: [{ action: 'addObject', body: { objectID: 'obj-1', title: 'First' } }]
			})
		);

		const result = await actions.uploadDocuments(
			makeActionArgs('uploadDocuments', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					documentsUploadError: 'upstream failed',
					documents: { ...EMPTY_DOCUMENTS }
				})
			})
		);
	});

	it('uploadDocuments action returns shared session failure for 401 upstream auth errors', async () => {
		addObjectsMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));
		const formData = new FormData();
		formData.set(
			'batch',
			JSON.stringify({
				requests: [{ action: 'addObject', body: { objectID: 'obj-1', title: 'First' } }]
			})
		);

		const result = await actions.uploadDocuments(
			makeActionArgs('uploadDocuments', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 401,
				data: expect.objectContaining({
					_authSessionExpired: true,
					error: 'Unauthorized'
				})
			})
		);
	});

	it('addDocument action wraps JSON record in addObject request and returns refreshed browse data', async () => {
		addObjectsMock.mockResolvedValue({ taskID: 100, objectIDs: ['obj-2'] });
		browseObjectsMock.mockResolvedValue({
			hits: [{ objectID: 'obj-2', title: 'Second' }],
			cursor: null,
			nbHits: 1,
			page: 0,
			nbPages: 1,
			hitsPerPage: 20,
			query: '',
			params: ''
		});

		const formData = new FormData();
		formData.set('document', JSON.stringify({ objectID: 'obj-2', title: 'Second' }));

		const result = await actions.addDocument(makeActionArgs('addDocument', formData) as never);

		expect(addObjectsMock).toHaveBeenCalledWith('products', {
			requests: [{ action: 'addObject', body: { objectID: 'obj-2', title: 'Second' } }]
		});
		expect(browseObjectsMock).toHaveBeenCalledWith('products', { query: '', hitsPerPage: 20 });
		expect(result).toEqual({
			documentsAddSuccess: true,
			documents: {
				hits: [{ objectID: 'obj-2', title: 'Second' }],
				cursor: null,
				nbHits: 1,
				page: 0,
				nbPages: 1,
				hitsPerPage: 20,
				query: '',
				params: ''
			}
		});
	});

	it('addDocument action rejects invalid JSON with fail(400)', async () => {
		const formData = new FormData();
		formData.set('document', '[');

		const result = await actions.addDocument(makeActionArgs('addDocument', formData) as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					documentsAddError: 'document must be valid JSON'
				})
			})
		);
		expect(addObjectsMock).not.toHaveBeenCalled();
	});

	it('addDocument action rejects empty submissions with fail(400)', async () => {
		const result = await actions.addDocument(
			makeActionArgs('addDocument', new FormData()) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					documentsAddError: 'document is required'
				})
			})
		);
		expect(addObjectsMock).not.toHaveBeenCalled();
	});

	it('browseDocuments action rejects invalid cursor input with fail(400)', async () => {
		const formData = new FormData();
		formData.set('cursor', '   ');

		const result = await actions.browseDocuments(
			makeActionArgs('browseDocuments', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					documentsBrowseError: 'cursor must not be empty when provided'
				})
			})
		);
		expect(browseObjectsMock).not.toHaveBeenCalled();
	});

	it('browseDocuments action returns fail(400) when browse request fails', async () => {
		browseObjectsMock.mockRejectedValue(new Error('browse upstream failed'));
		const formData = new FormData();
		formData.set('query', 'title:First');

		const result = await actions.browseDocuments(
			makeActionArgs('browseDocuments', formData) as never
		);

		expect(browseObjectsMock).toHaveBeenCalledWith('products', {
			query: 'title:First',
			hitsPerPage: 20
		});
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					documentsBrowseError: 'browse upstream failed',
					documents: { ...EMPTY_DOCUMENTS, query: 'title:First' }
				})
			})
		);
	});

	it('deleteDocument action deletes object and returns refreshed browse data', async () => {
		deleteObjectMock.mockResolvedValue({ taskID: 101, deletedAt: '2026-03-18T12:00:00Z' });
		browseObjectsMock.mockResolvedValue({
			hits: [],
			cursor: null,
			nbHits: 0,
			page: 0,
			nbPages: 0,
			hitsPerPage: 20,
			query: '',
			params: ''
		});

		const formData = new FormData();
		formData.set('objectID', 'obj-1');

		const result = await actions.deleteDocument(
			makeActionArgs('deleteDocument', formData) as never
		);

		expect(deleteObjectMock).toHaveBeenCalledWith('products', 'obj-1');
		expect(browseObjectsMock).toHaveBeenCalledWith('products', { query: '', hitsPerPage: 20 });
		expect(result).toEqual({
			documentsDeleteSuccess: true,
			documents: {
				hits: [],
				cursor: null,
				nbHits: 0,
				page: 0,
				nbPages: 0,
				hitsPerPage: 20,
				query: '',
				params: ''
			}
		});
	});

	it('deleteDocument action returns fail(400) when delete request fails', async () => {
		deleteObjectMock.mockRejectedValue(new Error('delete upstream failed'));
		const formData = new FormData();
		formData.set('objectID', 'obj-1');

		const result = await actions.deleteDocument(
			makeActionArgs('deleteDocument', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					documentsDeleteError: 'delete upstream failed',
					documents: { ...EMPTY_DOCUMENTS }
				})
			})
		);
	});

	it('uploadDocuments action rejects missing batch field with fail(400)', async () => {
		const formData = new FormData();
		formData.set('query', 'title:First');

		const result = await actions.uploadDocuments(
			makeActionArgs('uploadDocuments', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					documentsUploadError: 'batch is required',
					documents: { ...EMPTY_DOCUMENTS, query: 'title:First' }
				})
			})
		);
		expect(addObjectsMock).not.toHaveBeenCalled();
	});

	it('browseDocuments action returns browsed data on success', async () => {
		browseObjectsMock.mockResolvedValue({
			hits: [{ objectID: 'obj-1', title: 'First' }],
			cursor: 'abc',
			nbHits: 1,
			page: 0,
			nbPages: 1,
			hitsPerPage: 20,
			query: 'title:First',
			params: ''
		});

		const formData = new FormData();
		formData.set('query', 'title:First');
		formData.set('hitsPerPage', '20');

		const result = await actions.browseDocuments(
			makeActionArgs('browseDocuments', formData) as never
		);

		expect(browseObjectsMock).toHaveBeenCalledWith('products', {
			query: 'title:First',
			hitsPerPage: 20
		});
		expect(result).toEqual({
			documentsBrowseSuccess: true,
			documents: {
				hits: [{ objectID: 'obj-1', title: 'First' }],
				cursor: 'abc',
				nbHits: 1,
				page: 0,
				nbPages: 1,
				hitsPerPage: 20,
				query: 'title:First',
				params: ''
			}
		});
	});

	it('deleteDocument action rejects missing objectID with fail(400)', async () => {
		const formData = new FormData();

		const result = await actions.deleteDocument(
			makeActionArgs('deleteDocument', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					documentsDeleteError: 'objectID is required',
					documents: { ...EMPTY_DOCUMENTS }
				})
			})
		);
		expect(deleteObjectMock).not.toHaveBeenCalled();
	});

	it('refreshEvents action forwards optional filters to getDebugEvents', async () => {
		getDebugEventsMock.mockResolvedValue({ events: [], count: 0 });

		const formData = new FormData();
		formData.set('eventType', 'click');
		formData.set('status', 'error');
		formData.set('limit', '50');
		formData.set('from', '1709251200000');
		formData.set('until', '1709337600000');

		const result = await actions.refreshEvents(makeActionArgs('refreshEvents', formData) as never);

		expect(getDebugEventsMock).toHaveBeenCalledWith('products', {
			eventType: 'click',
			status: 'error',
			limit: 50,
			from: 1709251200000,
			until: 1709337600000
		});
		expect(result).toEqual({ refreshedEvents: { events: [], count: 0 } });
	});

	it('refreshEvents action rejects non-numeric limit with fail(400)', async () => {
		const formData = new FormData();
		formData.set('limit', 'abc');

		const result = await actions.refreshEvents(makeActionArgs('refreshEvents', formData) as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({ eventsError: 'limit must be a positive integer' })
			})
		);
		expect(getDebugEventsMock).not.toHaveBeenCalled();
	});

	it('refreshEvents action rejects non-numeric from timestamp with fail(400)', async () => {
		const formData = new FormData();
		formData.set('from', 'oops');

		const result = await actions.refreshEvents(makeActionArgs('refreshEvents', formData) as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({ eventsError: 'from must be a positive integer' })
			})
		);
		expect(getDebugEventsMock).not.toHaveBeenCalled();
	});
});
