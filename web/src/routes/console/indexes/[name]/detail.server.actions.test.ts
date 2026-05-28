import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import { makeActionArgs } from './detail.server.test.shared';
import { sampleExperiments } from './detail.test.shared';
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
const getIndexesMock = vi.fn();
const listExperimentsMock = vi.fn();
const getExperimentMock = vi.fn();
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
		getAnalyticsDevices: getAnalyticsDevicesMock,
		getAnalyticsCountries: getAnalyticsCountriesMock,
		getAnalyticsFilters: getAnalyticsFiltersMock,
		getAnalyticsConversionRate: getAnalyticsConversionRateMock,
		getDebugEvents: getDebugEventsMock,
		getIndexes: getIndexesMock,
		listExperiments: listExperimentsMock,
		getExperiment: getExperimentMock,
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
		getIndexesMock.mockResolvedValue([]);
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
				url: new URL('http://localhost/console/indexes/products')
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
				endAt: '2026-03-05T00:00:00.000Z',
				variants: [
					{ index: 'products', trafficPercentage: 50 },
					{
						index: 'products',
						trafficPercentage: 50,
						customSearchParameters: { enableRules: false }
					}
				]
			})
		);
		const result = await actions.createExperiment(
			makeActionArgs('createExperiment', formData) as never
		);
		expect(createExperimentMock).toHaveBeenCalledWith('products', {
			name: 'Ranking test',
			endAt: '2026-03-05T00:00:00.000Z',
			variants: [
				{ index: 'products', trafficPercentage: 50 },
				{ index: 'products', trafficPercentage: 50, customSearchParameters: { enableRules: false } }
			]
		});
		expect(result).toEqual({ experimentCreated: true });
	});
	it('createExperiment action retries transient API errors and succeeds', async () => {
		createExperimentMock
			.mockRejectedValueOnce(new ApiRequestError(503, 'endpoint not ready yet'))
			.mockResolvedValueOnce({ abTestID: 8, index: 'products', taskID: 2 });
		const formData = new FormData();
		formData.set(
			'experiment',
			JSON.stringify({
				name: 'Retry ranking test',
				endAt: '2026-03-10T00:00:00.000Z',
				variants: [
					{ index: 'products', trafficPercentage: 50 },
					{
						index: 'products',
						trafficPercentage: 50,
						customSearchParameters: { enableRules: true }
					}
				]
			})
		);
		const result = await actions.createExperiment(
			makeActionArgs('createExperiment', formData) as never
		);
		expect(createExperimentMock).toHaveBeenCalledTimes(2);
		expect(result).toEqual({ experimentCreated: true });
	});
	it('fetchAnalyticsDevices action forwards required date range and returns payload', async () => {
		getAnalyticsDevicesMock.mockResolvedValue({
			devices: { desktop: 11, mobile: 7, tablet: 2 }
		});
		const formData = new FormData();
		formData.set('startDate', '2026-02-18');
		formData.set('endDate', '2026-02-25');
		const result = await actions.fetchAnalyticsDevices(
			makeActionArgs('fetchAnalyticsDevices', formData) as never
		);
		expect(getAnalyticsDevicesMock).toHaveBeenCalledWith('products', {
			startDate: '2026-02-18',
			endDate: '2026-02-25'
		});
		expect(result).toEqual({
			analyticsDevices: { devices: { desktop: 11, mobile: 7, tablet: 2 } }
		});
	});
	it('fetchAnalyticsCountries action forwards required date range and returns payload', async () => {
		getAnalyticsCountriesMock.mockResolvedValue({
			countries: { US: 12, CA: 3 }
		});
		const formData = new FormData();
		formData.set('startDate', '2026-02-18');
		formData.set('endDate', '2026-02-25');
		const result = await actions.fetchAnalyticsCountries(
			makeActionArgs('fetchAnalyticsCountries', formData) as never
		);
		expect(getAnalyticsCountriesMock).toHaveBeenCalledWith('products', {
			startDate: '2026-02-18',
			endDate: '2026-02-25'
		});
		expect(result).toEqual({
			analyticsCountries: { countries: { US: 12, CA: 3 } }
		});
	});
	it('fetchAnalyticsFilters action forwards required date range and returns payload', async () => {
		getAnalyticsFiltersMock.mockResolvedValue({
			filters: {
				brand: { acme: 5 }
			}
		});
		const formData = new FormData();
		formData.set('startDate', '2026-02-18');
		formData.set('endDate', '2026-02-25');
		const result = await actions.fetchAnalyticsFilters(
			makeActionArgs('fetchAnalyticsFilters', formData) as never
		);
		expect(getAnalyticsFiltersMock).toHaveBeenCalledWith('products', {
			startDate: '2026-02-18',
			endDate: '2026-02-25'
		});
		expect(result).toEqual({
			analyticsFilters: {
				filters: {
					brand: { acme: 5 }
				}
			}
		});
	});
	it('fetchAnalyticsConversionRate action returns kpis, previous-period deltas, trend points, and country state', async () => {
		getAnalyticsConversionRateMock
			.mockResolvedValueOnce({
				conversions: {
					ctr: 0.12,
					addToCart: 0.34,
					purchase: 0.06,
					conversionRate: 0.025
				},
				trend: [
					{ date: '2026-02-18', conversionRate: 0.02 },
					{ date: '2026-02-19', conversionRate: 0.024 },
					{ date: '2026-02-20', conversionRate: 0.025 }
				],
				countries: ['US', 'CA']
			})
			.mockResolvedValueOnce({
				conversions: {
					ctr: 0.1,
					addToCart: 0.3,
					purchase: 0.05,
					conversionRate: 0.02
				}
			});
		const formData = new FormData();
		formData.set('startDate', '2026-02-18');
		formData.set('endDate', '2026-02-25');
		formData.set('country', 'US');
		const result = await actions.fetchAnalyticsConversionRate(
			makeActionArgs('fetchAnalyticsConversionRate', formData) as never
		);
		expect(getAnalyticsConversionRateMock).toHaveBeenNthCalledWith(1, 'products', {
			startDate: '2026-02-18',
			endDate: '2026-02-25',
			country: 'US'
		});
		expect(getAnalyticsConversionRateMock).toHaveBeenNthCalledWith(2, 'products', {
			startDate: '2026-02-10',
			endDate: '2026-02-17',
			country: 'US'
		});
		expect(result).toEqual({
			analyticsConversionRate: {
				country: 'US',
				countries: ['US', 'CA'],
				trend: [
					{ date: '2026-02-18', conversionRate: 0.02 },
					{ date: '2026-02-19', conversionRate: 0.024 },
					{ date: '2026-02-20', conversionRate: 0.025 }
				],
				kpis: {
					ctr: { current: 0.12, previous: 0.1, delta: 0.02 },
					addToCart: { current: 0.34, previous: 0.3, delta: 0.04 },
					purchase: { current: 0.06, previous: 0.05, delta: 0.01 },
					conversionRate: { current: 0.025, previous: 0.02, delta: 0.005 }
				}
			}
		});
	});
	it('appendSecuritySource keeps a reload failure visible instead of replacing the list with an empty fallback', async () => {
		appendSecuritySourceMock.mockResolvedValue(undefined);
		getSecuritySourcesMock.mockRejectedValue(new Error('reload unavailable'));
		const formData = new FormData();
		formData.set('source', '192.168.1.0/24');
		formData.set('description', 'Office network');
		const result = await actions.appendSecuritySource(
			makeActionArgs('appendSecuritySource', formData) as never
		);
		expect(appendSecuritySourceMock).toHaveBeenCalledWith('products', {
			source: '192.168.1.0/24',
			description: 'Office network'
		});
		expect(result).toEqual({
			securitySourceAppended: true,
			securitySourcesLoadError: 'reload unavailable'
		});
	});
	it('deleteSecuritySource keeps a reload failure visible instead of returning empty sources', async () => {
		deleteSecuritySourceMock.mockResolvedValue(undefined);
		getSecuritySourcesMock.mockRejectedValue(new Error('reload unavailable'));
		const formData = new FormData();
		formData.set('source', '192.168.1.0/24');
		const result = await actions.deleteSecuritySource(
			makeActionArgs('deleteSecuritySource', formData) as never
		);
		expect(deleteSecuritySourceMock).toHaveBeenCalledWith('products', '192.168.1.0/24');
		expect(result).toEqual({
			securitySourceDeleted: true,
			securitySourcesLoadError: 'reload unavailable'
		});
	});
	it('deleteExperiment action calls deleteExperiment API and returns success', async () => {
		getExperimentMock.mockResolvedValue({ ...sampleExperiments.abtests[1] });
		deleteExperimentMock.mockResolvedValue({ abTestID: 7, index: 'products', taskID: 1 });
		const formData = new FormData();
		formData.set('experimentID', '7');
		const result = await actions.deleteExperiment(
			makeActionArgs('deleteExperiment', formData) as never
		);
		expect(deleteExperimentMock).toHaveBeenCalledWith('products', 7);
		expect(result).toEqual({ experimentDeleted: true });
	});
	it('deleteExperiment action permits created experiments so detail and list flows stay aligned', async () => {
		getExperimentMock.mockResolvedValue({ ...sampleExperiments.abtests[0], status: 'created' });
		deleteExperimentMock.mockResolvedValue({ abTestID: 7, index: 'products', taskID: 1 });
		const formData = new FormData();
		formData.set('experimentID', '7');
		const result = await actions.deleteExperiment(
			makeActionArgs('deleteExperiment', formData) as never
		);
		expect(deleteExperimentMock).toHaveBeenCalledWith('products', 7);
		expect(result).toEqual({ experimentDeleted: true });
	});
	it('deleteExperiment action rejects zero experimentID with fail(400)', async () => {
		const formData = new FormData();
		formData.set('experimentID', '0');
		const result = await actions.deleteExperiment(
			makeActionArgs('deleteExperiment', formData) as never
		);
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					experimentError: 'experimentID must be a positive integer'
				})
			})
		);
		expect(deleteExperimentMock).not.toHaveBeenCalled();
	});
	it('deleteExperiment action blocks direct POST deletes for active experiments', async () => {
		getExperimentMock.mockResolvedValue({ ...sampleExperiments.abtests[0], status: 'running' });
		const formData = new FormData();
		formData.set('experimentID', '7');
		const result = await actions.deleteExperiment(
			makeActionArgs('deleteExperiment', formData) as never
		);
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					experimentError: 'Active experiments must be stopped before they can be deleted.'
				})
			})
		);
		expect(deleteExperimentMock).not.toHaveBeenCalled();
	});
	it('startExperiment action calls startExperiment API and returns success', async () => {
		getExperimentMock.mockResolvedValue({ ...sampleExperiments.abtests[0], status: 'created' });
		startExperimentMock.mockResolvedValue({ abTestID: 7, index: 'products', taskID: 1 });
		const formData = new FormData();
		formData.set('experimentID', '7');
		const result = await actions.startExperiment(
			makeActionArgs('startExperiment', formData) as never
		);
		expect(startExperimentMock).toHaveBeenCalledWith('products', 7);
		expect(result).toEqual({ experimentStarted: true });
	});
	it('startExperiment action blocks direct POST starts for non-created experiments', async () => {
		getExperimentMock.mockResolvedValue({ ...sampleExperiments.abtests[0], status: 'running' });
		const formData = new FormData();
		formData.set('experimentID', '7');
		const result = await actions.startExperiment(
			makeActionArgs('startExperiment', formData) as never
		);
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					experimentError: 'Only created experiments can be started.'
				})
			})
		);
		expect(startExperimentMock).not.toHaveBeenCalled();
	});
	it('stopExperiment action calls stopExperiment API and returns success', async () => {
		getExperimentMock.mockResolvedValue({ ...sampleExperiments.abtests[0], status: 'running' });
		stopExperimentMock.mockResolvedValue({ abTestID: 7, index: 'products', taskID: 1 });
		const formData = new FormData();
		formData.set('experimentID', '7');
		const result = await actions.stopExperiment(
			makeActionArgs('stopExperiment', formData) as never
		);
		expect(stopExperimentMock).toHaveBeenCalledWith('products', 7);
		expect(result).toEqual({ experimentStopped: true });
	});
	it('stopExperiment action blocks direct POST stops for non-active experiments', async () => {
		getExperimentMock.mockResolvedValue({ ...sampleExperiments.abtests[0], status: 'stopped' });
		const formData = new FormData();
		formData.set('experimentID', '7');
		const result = await actions.stopExperiment(
			makeActionArgs('stopExperiment', formData) as never
		);
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					experimentError: 'Only active experiments can be stopped.'
				})
			})
		);
		expect(stopExperimentMock).not.toHaveBeenCalled();
	});
	it('concludeExperiment action calls concludeExperiment API and returns success', async () => {
		getExperimentMock.mockResolvedValue({ ...sampleExperiments.abtests[0], status: 'running' });
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
	it('concludeExperiment action blocks direct POST promotion when no promotable overrides exist', async () => {
		getExperimentMock.mockResolvedValue({
			...sampleExperiments.abtests[0],
			status: 'running',
			variants: [
				{ index: 'products', trafficPercentage: 50 },
				{ index: 'products', trafficPercentage: 50 }
			]
		});
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
				promoted: true
			})
		);
		const result = await actions.concludeExperiment(
			makeActionArgs('concludeExperiment', formData) as never
		);
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					experimentError:
						'Winner promotion is only allowed when the experiment changes base-index settings.'
				})
			})
		);
		expect(concludeExperimentMock).not.toHaveBeenCalled();
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
	it('saveRule uses objectID from form field and forwards parsed rule JSON unchanged', async () => {
		saveRuleMock.mockResolvedValue({ taskID: 8, id: 'form-object-id' });
		const formData = new FormData();
		formData.set('objectID', 'form-object-id');
		formData.set(
			'rule',
			JSON.stringify({
				objectID: 'different-payload-id',
				conditions: [{ pattern: 'tablet', anchoring: 'contains' }],
				consequence: { params: { optionalWords: ['tablet'] } }
			})
		);
		await actions.saveRule(makeActionArgs('saveRule', formData) as never);
		expect(saveRuleMock).toHaveBeenCalledWith('products', 'form-object-id', {
			objectID: 'different-payload-id',
			conditions: [{ pattern: 'tablet', anchoring: 'contains' }],
			consequence: { params: { optionalWords: ['tablet'] } }
		});
	});
	it('deleteRule action calls deleteRule API with objectID', async () => {
		deleteRuleMock.mockResolvedValue({ taskID: 12, deletedAt: '2026-02-25T02:00:00Z' });
		const formData = new FormData();
		formData.set('objectID', 'boost-shoes');
		const result = await actions.deleteRule(makeActionArgs('deleteRule', formData) as never);
		expect(deleteRuleMock).toHaveBeenCalledWith('products', 'boost-shoes');
		expect(result).toEqual({ ruleDeleted: true });
	});
	it('deleteRule returns ruleError on delete failure', async () => {
		deleteRuleMock.mockRejectedValue(new Error('delete failed'));
		const formData = new FormData();
		formData.set('objectID', 'boost-shoes');
		const result = await actions.deleteRule(makeActionArgs('deleteRule', formData) as never);
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({ ruleError: 'delete failed' })
			})
		);
	});
	it('clearRules deletes every rule by repeatedly scanning page 0 and returns rulesCleared', async () => {
		searchRulesMock
			.mockResolvedValueOnce({
				hits: [{ objectID: 'rule-1' }, { objectID: 'rule-2' }],
				nbHits: 2,
				page: 0,
				nbPages: 1
			})
			.mockResolvedValueOnce({
				hits: [{ objectID: 'rule-3' }],
				nbHits: 1,
				page: 0,
				nbPages: 1
			})
			.mockResolvedValueOnce({
				hits: [],
				nbHits: 0,
				page: 0,
				nbPages: 0
			});
		deleteRuleMock.mockResolvedValue({ taskID: 1 });
		const result = await actions.clearRules(makeActionArgs('clearRules', new FormData()) as never);
		expect(searchRulesMock).toHaveBeenNthCalledWith(1, 'products');
		expect(searchRulesMock).toHaveBeenNthCalledWith(2, 'products');
		expect(searchRulesMock).toHaveBeenNthCalledWith(3, 'products');
		expect(deleteRuleMock).toHaveBeenNthCalledWith(1, 'products', 'rule-1');
		expect(deleteRuleMock).toHaveBeenNthCalledWith(2, 'products', 'rule-2');
		expect(deleteRuleMock).toHaveBeenNthCalledWith(3, 'products', 'rule-3');
		expect(result).toEqual({ rulesCleared: true });
	});
	it('clearRules returns rulesClearError when one delete fails', async () => {
		searchRulesMock
			.mockResolvedValueOnce({
				hits: [{ objectID: 'rule-1' }, { objectID: 'rule-2' }],
				nbHits: 2,
				page: 0,
				nbPages: 1
			})
			.mockResolvedValueOnce({
				hits: [{ objectID: 'rule-2' }],
				nbHits: 1,
				page: 0,
				nbPages: 1
			});
		deleteRuleMock.mockRejectedValueOnce(new Error('cannot delete rule-1'));
		const result = await actions.clearRules(makeActionArgs('clearRules', new FormData()) as never);
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({ rulesClearError: 'cannot delete rule-1' })
			})
		);
	});
	it('clearRules waits for deletion visibility and does not re-delete stale page-0 rule IDs', async () => {
		searchRulesMock.mockReset();
		deleteRuleMock.mockReset();
		searchRulesMock
			.mockResolvedValueOnce({
				hits: [{ objectID: 'rule-1' }],
				nbHits: 1,
				page: 0,
				nbPages: 1
			})
			.mockResolvedValueOnce({
				hits: [{ objectID: 'rule-1' }],
				nbHits: 1,
				page: 0,
				nbPages: 1
			})
			.mockResolvedValueOnce({
				hits: [],
				nbHits: 0,
				page: 0,
				nbPages: 0
			});
		deleteRuleMock.mockResolvedValue({ taskID: 1 });
		const result = await actions.clearRules(makeActionArgs('clearRules', new FormData()) as never);
		expect(searchRulesMock).toHaveBeenNthCalledWith(1, 'products');
		expect(searchRulesMock).toHaveBeenNthCalledWith(2, 'products');
		expect(searchRulesMock).toHaveBeenNthCalledWith(3, 'products');
		expect(deleteRuleMock).toHaveBeenCalledTimes(1);
		expect(deleteRuleMock).toHaveBeenCalledWith('products', 'rule-1');
		expect(result).toEqual({ rulesCleared: true });
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
	it('saveQsConfig action returns validation error when config is missing', async () => {
		const result = await actions.saveQsConfig(
			makeActionArgs('saveQsConfig', new FormData()) as never
		);
		expect(saveQsConfigMock).not.toHaveBeenCalled();
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({ qsConfigError: 'Suggestions config JSON is required' })
			})
		);
	});
	it('saveQsConfig action returns parse error and does not call API for invalid JSON', async () => {
		const formData = new FormData();
		formData.set('config', '{invalid-json');
		const result = await actions.saveQsConfig(makeActionArgs('saveQsConfig', formData) as never);
		expect(saveQsConfigMock).not.toHaveBeenCalled();
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({ qsConfigError: 'config must be valid JSON' })
			})
		);
	});
	it('saveQsConfig action surfaces upstream failures as qsConfigError', async () => {
		saveQsConfigMock.mockRejectedValue(new Error('qs save failed upstream'));
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
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({ qsConfigError: 'qs save failed upstream' })
			})
		);
	});
	it('deleteQsConfig action calls deleteQsConfig API', async () => {
		deleteQsConfigMock.mockResolvedValue({ deletedAt: '2026-02-25T04:00:00Z' });
		const result = await actions.deleteQsConfig(
			makeActionArgs('deleteQsConfig', new FormData()) as never
		);
		expect(deleteQsConfigMock).toHaveBeenCalledWith('products');
		expect(result).toEqual({ qsConfigDeleted: true });
	});
	it('deleteQsConfig action surfaces upstream failures as qsConfigError', async () => {
		deleteQsConfigMock.mockRejectedValue(new Error('qs delete failed upstream'));
		const result = await actions.deleteQsConfig(
			makeActionArgs('deleteQsConfig', new FormData()) as never
		);
		expect(deleteQsConfigMock).toHaveBeenCalledWith('products');
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({ qsConfigError: 'qs delete failed upstream' })
			})
		);
	});
});
