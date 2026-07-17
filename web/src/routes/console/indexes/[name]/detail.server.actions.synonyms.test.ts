import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import { makeActionArgs } from './detail.server.test.shared';

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
const getAnalyticsDevicesMock = vi.fn();
const getAnalyticsCountriesMock = vi.fn();
const getAnalyticsFiltersMock = vi.fn();
const getAnalyticsConversionRateMock = vi.fn();
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
const clearSynonymsMock = vi.fn();
const saveQsConfigMock = vi.fn();
const deleteQsConfigMock = vi.fn();
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
		getAnalyticsDevices: getAnalyticsDevicesMock,
		getAnalyticsCountries: getAnalyticsCountriesMock,
		getAnalyticsFilters: getAnalyticsFiltersMock,
		getAnalyticsConversionRate: getAnalyticsConversionRateMock,
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
		clearSynonyms: clearSynonymsMock,
		saveQsConfig: saveQsConfigMock,
		deleteQsConfig: deleteQsConfigMock,
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

describe('Index detail page server -- actions (synonyms-preview)', () => {
	beforeEach(() => {
		vi.clearAllMocks();
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

	it('saveSynonym action rejects invalid synonym JSON without calling the API', async () => {
		const formData = new FormData();
		formData.set('objectID', 'laptop-syn');
		formData.set('synonym', '{"broken":');

		const result = await actions.saveSynonym(makeActionArgs('saveSynonym', formData) as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					synonymError: 'synonym must be valid JSON'
				})
			})
		);
		expect(saveSynonymMock).not.toHaveBeenCalled();
	});

	it('deleteSynonym action calls deleteSynonym API with objectID', async () => {
		deleteSynonymMock.mockResolvedValue({ taskID: 16, deletedAt: '2026-02-25T03:00:00Z' });

		const formData = new FormData();
		formData.set('objectID', 'laptop-syn');

		const result = await actions.deleteSynonym(makeActionArgs('deleteSynonym', formData) as never);

		expect(deleteSynonymMock).toHaveBeenCalledWith('products', 'laptop-syn');
		expect(result).toEqual({ synonymDeleted: true });
	});

	it('deleteSynonym action maps expired sessions to the shared dashboard-session payload', async () => {
		deleteSynonymMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const formData = new FormData();
		formData.set('objectID', 'laptop-syn');

		const result = await actions.deleteSynonym(makeActionArgs('deleteSynonym', formData) as never);

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

	it('clearSynonyms action calls clearSynonyms API and returns success', async () => {
		clearSynonymsMock.mockResolvedValue({ taskID: 17, status: 'enqueued' });

		const result = await actions.clearSynonyms(
			makeActionArgs('clearSynonyms', new FormData()) as never
		);

		expect(clearSynonymsMock).toHaveBeenCalledWith('products');
		expect(result).toEqual({ synonymsCleared: true });
	});

	it('clearSynonyms action maps expired sessions to the shared dashboard-session payload', async () => {
		clearSynonymsMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const result = await actions.clearSynonyms(
			makeActionArgs('clearSynonyms', new FormData()) as never
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
});
