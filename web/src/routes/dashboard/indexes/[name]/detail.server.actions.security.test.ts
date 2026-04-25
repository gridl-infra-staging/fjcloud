import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import { EMPTY_SECURITY_SOURCES, makeActionArgs } from './detail.server.test.shared';

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


describe("Index detail page server -- actions (security sources)", () => {
	beforeEach(() => {
		vi.clearAllMocks();
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
