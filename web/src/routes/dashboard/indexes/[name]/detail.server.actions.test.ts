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
});
