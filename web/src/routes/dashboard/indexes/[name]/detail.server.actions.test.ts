import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import {
	EMPTY_DOCUMENTS,
	EMPTY_DICTIONARIES,
	EMPTY_DICTIONARY_ENTRIES,
	EMPTY_SECURITY_SOURCES,
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

import { actions, load } from './+page.server';

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('Index detail page server -- actions', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('redirects to login when the detail load hits an expired session', async () => {
		getIndexMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));
		getIndexSettingsMock.mockResolvedValue(null);
		listReplicasMock.mockResolvedValue([]);
		getInternalRegionsMock.mockResolvedValue([]);
		browseObjectsMock.mockResolvedValue(null);
		searchRulesMock.mockResolvedValue(null);
		searchSynonymsMock.mockResolvedValue(null);
		getPersonalizationStrategyMock.mockResolvedValue(null);
		getQsConfigMock.mockResolvedValue(null);
		getQsStatusMock.mockResolvedValue(null);
		getAnalyticsSearchCountMock.mockResolvedValue(null);
		getAnalyticsNoResultRateMock.mockResolvedValue(null);
		getAnalyticsTopSearchesMock.mockResolvedValue(null);
		getAnalyticsNoResultsMock.mockResolvedValue(null);
		getAnalyticsStatusMock.mockResolvedValue(null);
		listExperimentsMock.mockResolvedValue(null);
		getDebugEventsMock.mockResolvedValue(null);

		await expect(
			load({
				locals: { user: { token: 'jwt-token' } },
				params: { name: 'products' },
				url: new URL('http://localhost/dashboard/indexes/products')
			} as never)
		).rejects.toMatchObject({
			status: 303,
			location: '/login?reason=session_expired'
		});
	});

	it('createExperiment action calls createExperiment API and returns success', async () => {
		createExperimentMock.mockResolvedValue({ abTestID: 7, index: 'products', taskID: 1 });

		const formData = new FormData();
		formData.set(
			'experiment',
			JSON.stringify({
				name: 'Ranking test',
				variants: [
					{ index: 'products', trafficPercentage: 50 },
					{ index: 'products', trafficPercentage: 50, customSearchParameters: { enableRules: false } }
				]
			})
		);

		const result = await actions.createExperiment(makeActionArgs('createExperiment', formData) as never);

		expect(createExperimentMock).toHaveBeenCalledWith('products', {
			name: 'Ranking test',
			variants: [
				{ index: 'products', trafficPercentage: 50 },
				{ index: 'products', trafficPercentage: 50, customSearchParameters: { enableRules: false } }
			]
		});
		expect(result).toEqual({ experimentCreated: true });
	});

	it('deleteExperiment action calls deleteExperiment API and returns success', async () => {
		deleteExperimentMock.mockResolvedValue({ abTestID: 7, index: 'products', taskID: 1 });

		const formData = new FormData();
		formData.set('experimentID', '7');

		const result = await actions.deleteExperiment(makeActionArgs('deleteExperiment', formData) as never);

		expect(deleteExperimentMock).toHaveBeenCalledWith('products', 7);
		expect(result).toEqual({ experimentDeleted: true });
	});

	it('deleteExperiment action rejects zero experimentID with fail(400)', async () => {
		const formData = new FormData();
		formData.set('experimentID', '0');

		const result = await actions.deleteExperiment(makeActionArgs('deleteExperiment', formData) as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({ experimentError: 'experimentID must be a positive integer' })
			})
		);
		expect(deleteExperimentMock).not.toHaveBeenCalled();
	});

	it('startExperiment action calls startExperiment API and returns success', async () => {
		startExperimentMock.mockResolvedValue({ abTestID: 7, index: 'products', taskID: 1 });

		const formData = new FormData();
		formData.set('experimentID', '7');

		const result = await actions.startExperiment(makeActionArgs('startExperiment', formData) as never);

		expect(startExperimentMock).toHaveBeenCalledWith('products', 7);
		expect(result).toEqual({ experimentStarted: true });
	});

	it('stopExperiment action calls stopExperiment API and returns success', async () => {
		stopExperimentMock.mockResolvedValue({ abTestID: 7, index: 'products', taskID: 1 });

		const formData = new FormData();
		formData.set('experimentID', '7');

		const result = await actions.stopExperiment(makeActionArgs('stopExperiment', formData) as never);

		expect(stopExperimentMock).toHaveBeenCalledWith('products', 7);
		expect(result).toEqual({ experimentStopped: true });
	});

	it('concludeExperiment action calls concludeExperiment API and returns success', async () => {
		concludeExperimentMock.mockResolvedValue({ abTestID: 7, index: 'products', taskID: 1 });

		const formData = new FormData();
		formData.set('experimentID', '7');
		formData.set(
			'conclusion',
			JSON.stringify({
				winner: 'variant',
				reason: 'variant has better ctr',
				controlMetric: 0.05,
				variantMetric: 0.08,
				confidence: 0.97,
				significant: true,
				promoted: false
			})
		);

		const result = await actions.concludeExperiment(
			makeActionArgs('concludeExperiment', formData) as never
		);

		expect(concludeExperimentMock).toHaveBeenCalledWith('products', 7, {
			winner: 'variant',
			reason: 'variant has better ctr',
			controlMetric: 0.05,
			variantMetric: 0.08,
			confidence: 0.97,
			significant: true,
			promoted: false
		});
		expect(result).toEqual({ experimentConcluded: true });
	});

	it('saveSettings action calls updateIndexSettings and returns success', async () => {
		updateIndexSettingsMock.mockResolvedValue({ taskID: 42, updatedAt: '2026-02-25T00:00:00Z' });

		const formData = new FormData();
		formData.set('settings', JSON.stringify({ searchableAttributes: ['title'] }));

		const result = await actions.saveSettings(makeActionArgs('saveSettings', formData) as never);

		expect(updateIndexSettingsMock).toHaveBeenCalledWith('products', {
			searchableAttributes: ['title']
		});
		expect(result).toEqual({ settingsSaved: true });
	});

	it('saveSettings action returns fail(400) when API call fails', async () => {
		updateIndexSettingsMock.mockRejectedValue(new Error('upstream failed'));

		const formData = new FormData();
		formData.set('settings', JSON.stringify({ searchableAttributes: ['title'] }));

		const result = await actions.saveSettings(makeActionArgs('saveSettings', formData) as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400
			})
		);
	});

	it('saveSettings action rejects array body with fail(400)', async () => {
		const formData = new FormData();
		formData.set('settings', JSON.stringify(['title', 'body']));

		const result = await actions.saveSettings(makeActionArgs('saveSettings', formData) as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400
			})
		);
		expect(updateIndexSettingsMock).not.toHaveBeenCalled();
	});

	it('saveRule action calls saveRule API with objectID and parsed rule JSON', async () => {
		saveRuleMock.mockResolvedValue({ taskID: 7, id: 'boost-shoes' });

		const formData = new FormData();
		formData.set('objectID', 'boost-shoes');
		formData.set(
			'rule',
			JSON.stringify({
				objectID: 'boost-shoes',
				conditions: [{ pattern: 'shoes', anchoring: 'contains' }],
				consequence: { promote: [{ objectID: 'shoe-1', position: 0 }] }
			})
		);

		const result = await actions.saveRule(makeActionArgs('saveRule', formData) as never);

		expect(saveRuleMock).toHaveBeenCalledWith('products', 'boost-shoes', {
			objectID: 'boost-shoes',
			conditions: [{ pattern: 'shoes', anchoring: 'contains' }],
			consequence: { promote: [{ objectID: 'shoe-1', position: 0 }] }
		});
		expect(result).toEqual({ ruleSaved: true });
	});

	it('deleteRule action calls deleteRule API with objectID', async () => {
		deleteRuleMock.mockResolvedValue({ taskID: 12, deletedAt: '2026-02-25T02:00:00Z' });

		const formData = new FormData();
		formData.set('objectID', 'boost-shoes');

		const result = await actions.deleteRule(makeActionArgs('deleteRule', formData) as never);

		expect(deleteRuleMock).toHaveBeenCalledWith('products', 'boost-shoes');
		expect(result).toEqual({ ruleDeleted: true });
	});

	it('saveSynonym action calls saveSynonym API with objectID and parsed synonym JSON', async () => {
		saveSynonymMock.mockResolvedValue({ taskID: 15, id: 'laptop-syn' });

		const formData = new FormData();
		formData.set('objectID', 'laptop-syn');
		formData.set(
			'synonym',
			JSON.stringify({
				objectID: 'laptop-syn',
				type: 'synonym',
				synonyms: ['laptop', 'notebook']
			})
		);

		const result = await actions.saveSynonym(makeActionArgs('saveSynonym', formData) as never);

		expect(saveSynonymMock).toHaveBeenCalledWith('products', 'laptop-syn', {
			objectID: 'laptop-syn',
			type: 'synonym',
			synonyms: ['laptop', 'notebook']
		});
		expect(result).toEqual({ synonymSaved: true });
	});

	it('deleteSynonym action calls deleteSynonym API with objectID', async () => {
		deleteSynonymMock.mockResolvedValue({ taskID: 16, deletedAt: '2026-02-25T03:00:00Z' });

		const formData = new FormData();
		formData.set('objectID', 'laptop-syn');

		const result = await actions.deleteSynonym(makeActionArgs('deleteSynonym', formData) as never);

		expect(deleteSynonymMock).toHaveBeenCalledWith('products', 'laptop-syn');
		expect(result).toEqual({ synonymDeleted: true });
	});


	it('saveQsConfig action calls saveQsConfig API with parsed config JSON', async () => {
		saveQsConfigMock.mockResolvedValue({ status: 'updated' });

		const formData = new FormData();
		formData.set(
			'config',
			JSON.stringify({
				indexName: 'products',
				sourceIndices: [],
				languages: ['en'],
				exclude: [],
				allowSpecialCharacters: false,
				enablePersonalization: false
			})
		);

		const result = await actions.saveQsConfig(makeActionArgs('saveQsConfig', formData) as never);

		expect(saveQsConfigMock).toHaveBeenCalledWith('products', {
			indexName: 'products',
			sourceIndices: [],
			languages: ['en'],
			exclude: [],
			allowSpecialCharacters: false,
			enablePersonalization: false
		});
		expect(result).toEqual({ qsConfigSaved: true });
	});

	it('deleteQsConfig action calls deleteQsConfig API', async () => {
		deleteQsConfigMock.mockResolvedValue({ deletedAt: '2026-02-25T04:00:00Z' });

		const result = await actions.deleteQsConfig(
			makeActionArgs('deleteQsConfig', new FormData()) as never
		);

		expect(deleteQsConfigMock).toHaveBeenCalledWith('products');
		expect(result).toEqual({ qsConfigDeleted: true });
	});

	it('createPreviewKey action calls createIndexKey with search ACL and returns key', async () => {
		createIndexKeyMock.mockResolvedValue({ key: 'fj_preview_abc123', createdAt: '2026-03-15T00:00:00Z' });

		const result = await actions.createPreviewKey(
			makeActionArgs('createPreviewKey', new FormData()) as never
		);

		expect(createIndexKeyMock).toHaveBeenCalledWith('products', 'Search preview', ['search']);
		expect(result).toEqual({
			previewKey: 'fj_preview_abc123',
			previewIndexName: 'cust1_products'
		});
	});

	it('createPreviewKey action returns previewKeyError when API call fails', async () => {
		createIndexKeyMock.mockRejectedValue(new Error('upstream failed'));

		const result = await actions.createPreviewKey(
			makeActionArgs('createPreviewKey', new FormData()) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({ previewKeyError: 'upstream failed' })
			})
		);
	});

	it('createPreviewKey action retries transient endpoint warmup failures before succeeding', async () => {
		vi.useFakeTimers();
		try {
			createIndexKeyMock
				.mockRejectedValueOnce(new ApiRequestError(400, 'endpoint not ready yet'))
				.mockRejectedValueOnce(new ApiRequestError(503, 'warming up'))
				.mockResolvedValueOnce({ key: 'fj_preview_retry', createdAt: '2026-03-15T00:00:00Z' });

			const resultPromise = actions.createPreviewKey(
				makeActionArgs('createPreviewKey', new FormData()) as never
			);

			await vi.runAllTimersAsync();

			const result = await resultPromise;
			expect(createIndexKeyMock).toHaveBeenCalledTimes(3);
			expect(result).toEqual({
				previewKey: 'fj_preview_retry',
				previewIndexName: 'cust1_products'
			});
		} finally {
			vi.useRealTimers();
		}
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
		const result = await actions.addDocument(makeActionArgs('addDocument', new FormData()) as never);

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

		const result = await actions.deleteDocument(makeActionArgs('deleteDocument', formData) as never);

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

		const result = await actions.deleteDocument(makeActionArgs('deleteDocument', formData) as never);

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

		const result = await actions.deleteDocument(makeActionArgs('deleteDocument', formData) as never);

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

	// ---------------------------------------------------------------------------
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
			requests: [{ action: 'addEntry', body: { objectID: 'stop-the', language: 'en', word: 'the' } }]
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

	// --- Security Sources actions ---

	it('appendSecuritySource action calls appendSecuritySource API and returns success', async () => {
		appendSecuritySourceMock.mockResolvedValue({ createdAt: '2026-03-19T00:00:00Z' });
		getSecuritySourcesMock.mockResolvedValue({
			sources: [{ source: '10.0.0.0/8', description: 'VPN range' }]
		});

		const formData = new FormData();
		formData.set('source', '10.0.0.0/8');
		formData.set('description', 'VPN range');

		const result = await actions.appendSecuritySource(
			makeActionArgs('appendSecuritySource', formData) as never
		);

		expect(appendSecuritySourceMock).toHaveBeenCalledWith('products', {
			source: '10.0.0.0/8',
			description: 'VPN range'
		});
		expect(result).toEqual(
			expect.objectContaining({
				securitySourceAppended: true,
				securitySources: {
					sources: [{ source: '10.0.0.0/8', description: 'VPN range' }]
				}
			})
		);
	});

	it('appendSecuritySource action rejects missing source with fail(400)', async () => {
		const formData = new FormData();
		formData.set('description', 'some desc');

		const result = await actions.appendSecuritySource(
			makeActionArgs('appendSecuritySource', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					securitySourceAppendError: 'source is required',
					securitySources: { ...EMPTY_SECURITY_SOURCES }
				})
			})
		);
		expect(appendSecuritySourceMock).not.toHaveBeenCalled();
	});

	it('appendSecuritySource action returns shared session failure for 401 upstream auth errors', async () => {
		appendSecuritySourceMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const formData = new FormData();
		formData.set('source', '10.0.0.0/8');
		formData.set('description', 'VPN range');

		const result = await actions.appendSecuritySource(
			makeActionArgs('appendSecuritySource', formData) as never
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

	it('deleteSecuritySource action forwards raw CIDR value without double-encoding', async () => {
		deleteSecuritySourceMock.mockResolvedValue({ deletedAt: '2026-03-19T01:00:00Z' });
		getSecuritySourcesMock.mockResolvedValue({ sources: [] });

		const formData = new FormData();
		formData.set('source', '192.168.1.0/24');

		const result = await actions.deleteSecuritySource(
			makeActionArgs('deleteSecuritySource', formData) as never
		);

		// The action passes the raw CIDR value — encoding is the client's job
		expect(deleteSecuritySourceMock).toHaveBeenCalledWith('products', '192.168.1.0/24');
		expect(result).toEqual(
			expect.objectContaining({
				securitySourceDeleted: true,
				securitySources: { sources: [] }
			})
		);
	});

	it('deleteSecuritySource action rejects missing source with fail(400)', async () => {
		const formData = new FormData();

		const result = await actions.deleteSecuritySource(
			makeActionArgs('deleteSecuritySource', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					securitySourceDeleteError: 'source is required',
					securitySources: { ...EMPTY_SECURITY_SOURCES }
				})
			})
		);
		expect(deleteSecuritySourceMock).not.toHaveBeenCalled();
	});
});
