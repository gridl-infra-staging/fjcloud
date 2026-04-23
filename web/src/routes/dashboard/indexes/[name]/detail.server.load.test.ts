import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import {
	type MockFns,
	DEFAULT_INDEX,
	EMPTY_DOCUMENTS,
	EMPTY_DICTIONARIES,
	EMPTY_SECURITY_SOURCES,
	setupDefaultLoadMocks,
	makeLoadArgs
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
const savePersonalizationStrategyMock = vi.fn();
const deletePersonalizationStrategyMock = vi.fn();
const getPersonalizationProfileMock = vi.fn();
const deletePersonalizationProfileMock = vi.fn();
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
		savePersonalizationStrategy: savePersonalizationStrategyMock,
		deletePersonalizationStrategy: deletePersonalizationStrategyMock,
		getPersonalizationProfile: getPersonalizationProfileMock,
		deletePersonalizationProfile: deletePersonalizationProfileMock,
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

import { load } from './+page.server';

type LoadResult = Exclude<Awaited<ReturnType<typeof load>>, void>;

// ---------------------------------------------------------------------------
// Collected mock references for helper functions
// ---------------------------------------------------------------------------

const mocks: MockFns = {
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
	savePersonalizationStrategy: savePersonalizationStrategyMock,
	deletePersonalizationStrategy: deletePersonalizationStrategyMock,
	getPersonalizationProfile: getPersonalizationProfileMock,
	deletePersonalizationProfile: deletePersonalizationProfileMock,
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
	getDictionaryLanguages: getDictionaryLanguagesMock,
	searchDictionaryEntries: searchDictionaryEntriesMock,
	batchDictionaryEntries: batchDictionaryEntriesMock,
	getSecuritySources: getSecuritySourcesMock,
	appendSecuritySource: appendSecuritySourceMock,
	deleteSecuritySource: deleteSecuritySourceMock
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('Index detail page server -- load', () => {
	beforeEach(() => {
		vi.clearAllMocks();
		setupDefaultLoadMocks(mocks);
	});

	afterEach(() => {
		vi.useRealTimers();
	});

	it('load fetches rules along with index/settings/replicas/regions', async () => {
		getIndexMock.mockResolvedValue({
			...DEFAULT_INDEX
		});
		getIndexSettingsMock.mockResolvedValue({ searchableAttributes: ['title'] });
		searchRulesMock.mockResolvedValue({
			hits: [{ objectID: 'boost-shoes', conditions: [], consequence: {} }],
			nbHits: 1,
			page: 0,
			nbPages: 1
		});
		searchSynonymsMock.mockResolvedValue({
			hits: [{ objectID: 'laptop-syn', type: 'synonym', synonyms: ['laptop', 'notebook'] }],
			nbHits: 1
		});
		getQsConfigMock.mockResolvedValue({
			indexName: 'products',
			sourceIndices: [],
			languages: ['en'],
			exclude: [],
			allowSpecialCharacters: false,
			enablePersonalization: false
		});
		getQsStatusMock.mockResolvedValue({
			indexName: 'products',
			isRunning: false,
			lastBuiltAt: null,
			lastSuccessfulBuiltAt: null
		});

		const result = (await load(makeLoadArgs() as never)) as LoadResult;

		expect(searchRulesMock).toHaveBeenCalledWith('products');
		expect(result.rules.nbHits).toBe(1);
		expect(result.rules.hits[0].objectID).toBe('boost-shoes');
		expect(result.synonyms.nbHits).toBe(1);
		expect(result.synonyms.hits[0].objectID).toBe('laptop-syn');
		expect(result.personalizationStrategy).toBeNull();
		expect(result.qsConfig?.indexName).toBe('products');
		expect(result.qsStatus?.isRunning).toBe(false);
	});

	it('load includes personalization strategy when API returns one', async () => {
		getPersonalizationStrategyMock.mockResolvedValue({
			eventsScoring: [
				{ eventName: 'Product viewed', eventType: 'view', score: 10 },
				{ eventName: 'Product purchased', eventType: 'conversion', score: 50 }
			],
			facetsScoring: [
				{ facetName: 'brand', score: 70 },
				{ facetName: 'category', score: 30 }
			],
			personalizationImpact: 75
		});

		const result = (await load(makeLoadArgs() as never)) as LoadResult;

		expect(getPersonalizationStrategyMock).toHaveBeenCalledWith('products');
		expect(result.personalizationStrategy).toEqual({
			eventsScoring: [
				{ eventName: 'Product viewed', eventType: 'view', score: 10 },
				{ eventName: 'Product purchased', eventType: 'conversion', score: 50 }
			],
			facetsScoring: [
				{ facetName: 'brand', score: 70 },
				{ facetName: 'category', score: 30 }
			],
			personalizationImpact: 75
		});
	});

	it('load fetches initial documents browse payload with canonical shape', async () => {
		browseObjectsMock.mockResolvedValue({
			hits: [{ objectID: 'obj-1', title: 'First' }],
			cursor: 'next-cursor',
			nbHits: 1,
			page: 0,
			nbPages: 1,
			hitsPerPage: 20,
			query: '',
			params: ''
		});

		const result = (await load(makeLoadArgs() as never)) as LoadResult;

		expect(browseObjectsMock).toHaveBeenCalledWith('products', { hitsPerPage: 20, query: '' });
		expect(result.documents).toEqual({
			hits: [{ objectID: 'obj-1', title: 'First' }],
			cursor: 'next-cursor',
			nbHits: 1,
			page: 0,
			nbPages: 1,
			hitsPerPage: 20,
			query: '',
			params: ''
		});
	});

	it('load falls back to empty rules when rules fetch fails', async () => {
		searchRulesMock.mockRejectedValue(new Error('rules unavailable'));
		browseObjectsMock.mockRejectedValue(new Error('browse unavailable'));
		searchSynonymsMock.mockRejectedValue(new Error('synonyms unavailable'));
		getPersonalizationStrategyMock.mockRejectedValue(new Error('personalization unavailable'));
		getQsConfigMock.mockRejectedValue(new Error('qs unavailable'));
		getQsStatusMock.mockRejectedValue(new Error('qs status unavailable'));
		getAnalyticsTopSearchesMock.mockRejectedValue(new Error('analytics unavailable'));
		getAnalyticsSearchCountMock.mockRejectedValue(new Error('analytics unavailable'));
		getAnalyticsNoResultsMock.mockRejectedValue(new Error('analytics unavailable'));
		getAnalyticsNoResultRateMock.mockRejectedValue(new Error('analytics unavailable'));
		getAnalyticsStatusMock.mockRejectedValue(new Error('analytics unavailable'));
		listExperimentsMock.mockRejectedValue(new Error('experiments unavailable'));

		const result = (await load(makeLoadArgs() as never)) as LoadResult;

		expect(result.rules).toBeNull();
		expect(result.synonyms).toBeNull();
	expect(result.personalizationStrategy).toBeNull();
	expect(result.documents).toEqual({ ...EMPTY_DOCUMENTS });
	expect(result.qsConfig).toBeNull();
		expect(result.qsStatus).toBeNull();
		expect(result.searchCount).toBeNull();
		expect(result.noResultRate).toBeNull();
		expect(result.topSearches).toBeNull();
		expect(result.noResults).toBeNull();
		expect(result.analyticsStatus).toBeNull();
		expect(result.experiments).toBeNull();
	});

	it('load returns rules: null when only searchRules fails', async () => {
		searchRulesMock.mockRejectedValue(new Error('rules unavailable'));

		const result = (await load(makeLoadArgs() as never)) as LoadResult;

		expect(result.rules).toBeNull();
		// synonyms still loaded successfully via setupDefaultLoadMocks
		expect(result.synonyms).not.toBeNull();
		expect(result.synonyms).toHaveProperty('hits');
	});

	it('load returns synonyms: null when only searchSynonyms fails', async () => {
		searchSynonymsMock.mockRejectedValue(new Error('synonyms unavailable'));

		const result = (await load(makeLoadArgs() as never)) as LoadResult;

		expect(result.synonyms).toBeNull();
		// rules still loaded successfully via setupDefaultLoadMocks
		expect(result.rules).not.toBeNull();
		expect(result.rules).toHaveProperty('hits');
	});

	it('load fetches analytics search count with default 7-day range', async () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-02-25T12:00:00Z'));

		await load(makeLoadArgs() as never);

		expect(getAnalyticsSearchCountMock).toHaveBeenCalledWith('products', {
			startDate: '2026-02-19',
			endDate: '2026-02-25'
		});
	});

	it('load fetches analytics no-result rate for selected period', async () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-02-25T12:00:00Z'));

		await load(makeLoadArgs('?period=30d') as never);

		expect(getAnalyticsNoResultRateMock).toHaveBeenCalledWith('products', {
			startDate: '2026-01-27',
			endDate: '2026-02-25'
		});
	});

	it('load fetches analytics top searches with limit 10', async () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-02-25T12:00:00Z'));

		await load(makeLoadArgs() as never);

		expect(getAnalyticsTopSearchesMock).toHaveBeenCalledWith('products', {
			startDate: '2026-02-19',
			endDate: '2026-02-25',
			limit: 10
		});
	});

	it('load fetches analytics status', async () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-02-25T12:00:00Z'));

		listExperimentsMock.mockResolvedValue({
			abtests: [
				{
					abTestID: 7,
					name: 'Ranking test',
					status: 'created',
					endAt: '2026-03-15T00:00:00Z',
					createdAt: '2026-02-25T00:00:00Z',
					updatedAt: '2026-02-25T00:00:00Z',
					variants: [{ index: 'products', trafficPercentage: 50 }],
					configuration: {}
				}
			],
			count: 1,
			total: 1
		});

		await load(makeLoadArgs() as never);

		expect(getAnalyticsStatusMock).toHaveBeenCalledWith('products');
		expect(listExperimentsMock).toHaveBeenCalledWith('products');
	});

	it('load fetches experiment results map for listed experiments', async () => {
		listExperimentsMock.mockResolvedValue({
			abtests: [
				{
					abTestID: 7,
					name: 'Ranking test',
					status: 'running',
					endAt: '2026-03-15T00:00:00Z',
					createdAt: '2026-02-25T00:00:00Z',
					updatedAt: '2026-02-25T00:00:00Z',
					variants: [{ index: 'products', trafficPercentage: 50 }],
					configuration: {}
				},
				{
					abTestID: 9,
					name: 'Second test',
					status: 'created',
					endAt: '2026-03-20T00:00:00Z',
					createdAt: '2026-02-25T00:00:00Z',
					updatedAt: '2026-02-25T00:00:00Z',
					variants: [{ index: 'products', trafficPercentage: 50 }],
					configuration: {}
				}
			],
			count: 2,
			total: 2
		});
		getExperimentResultsMock
			.mockResolvedValueOnce({
				experimentID: '7',
				name: 'Ranking test',
				status: 'running',
				indexName: 'products',
				trafficSplit: 0.5,
				gate: {
					minimumNReached: true,
					minimumDaysReached: true,
					readyToRead: true,
					requiredSearchesPerArm: 1000,
					currentSearchesPerArm: 1200,
					progressPct: 100
				},
				control: {
					name: 'control',
					searches: 1200,
					users: 500,
					clicks: 140,
					conversions: 55,
					revenue: 0,
					ctr: 0.12,
					conversionRate: 0.04,
					revenuePerSearch: 0,
					zeroResultRate: 0.03,
					abandonmentRate: 0.14,
					meanClickRank: 3.2
				},
				variant: {
					name: 'variant',
					searches: 1200,
					users: 490,
					clicks: 160,
					conversions: 60,
					revenue: 0,
					ctr: 0.13,
					conversionRate: 0.05,
					revenuePerSearch: 0,
					zeroResultRate: 0.02,
					abandonmentRate: 0.12,
					meanClickRank: 2.8
				},
				primaryMetric: 'ctr',
				sampleRatioMismatch: false,
				guardRailAlerts: [],
				cupedApplied: true
			})
			.mockRejectedValueOnce(new Error('results unavailable'));

		const result = (await load(makeLoadArgs() as never)) as LoadResult;

		expect(getExperimentResultsMock).toHaveBeenCalledWith('products', 7);
		expect(getExperimentResultsMock).toHaveBeenCalledWith('products', 9);
		expect(result.experimentResults).toMatchObject({
			'7': {
				experimentID: '7',
				primaryMetric: 'ctr'
			}
		});
	});

	it('load fetches debug events with default limit and last-24h range', async () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-02-25T12:00:00Z'));

		await load(makeLoadArgs() as never);

		expect(getDebugEventsMock).toHaveBeenCalledWith('products', {
			limit: 100,
			from: 1771934400000,
			until: 1772020800000
		});

		vi.useRealTimers();
	});

	it('load returns dictionaries payload with default empty shape', async () => {
		const result = (await load(makeLoadArgs() as never)) as LoadResult;

		expect(result.dictionaries).toEqual({ ...EMPTY_DICTIONARIES });
	});

	it('load fetches dictionary languages and passes them through', async () => {
		getDictionaryLanguagesMock.mockResolvedValue({
			en: {
				stopwords: { nbCustomEntries: 2 },
				plurals: null,
				compounds: null
			},
			fr: {
				stopwords: null,
				plurals: { nbCustomEntries: 1 },
				compounds: null
			}
		});

		const result = (await load(makeLoadArgs() as never)) as LoadResult;

		expect(getDictionaryLanguagesMock).toHaveBeenCalledWith('products');
		expect(result.dictionaries.languages).toEqual({
			en: {
				stopwords: { nbCustomEntries: 2 },
				plurals: null,
				compounds: null
			},
			fr: {
				stopwords: null,
				plurals: { nbCustomEntries: 1 },
				compounds: null
			}
		});
	});

	it('load derives canonical dictionary selectors from languages response and fetches entries', async () => {
		getDictionaryLanguagesMock.mockResolvedValue({
			en: {
				stopwords: { nbCustomEntries: 2 },
				plurals: null,
				compounds: null
			},
			fr: {
				stopwords: null,
				plurals: { nbCustomEntries: 1 },
				compounds: null
			}
		});
		searchDictionaryEntriesMock.mockResolvedValue({
			hits: [{ objectID: 'plural-cat', language: 'fr', words: ['chat', 'chats'], type: 'custom' }],
			nbHits: 1,
			page: 0,
			nbPages: 1
		});

		const result = (await load(
			makeLoadArgs('?dictionary=plurals&dictionaryLang=fr') as never
		)) as LoadResult;

		expect(searchDictionaryEntriesMock).toHaveBeenCalledWith('products', 'plurals', {
			query: '',
			language: 'fr'
		});
		expect(result.dictionaries.selectedDictionary).toBe('plurals');
		expect(result.dictionaries.selectedLanguage).toBe('fr');
		expect(result.dictionaries.entries.hits).toHaveLength(1);
		expect(result.dictionaries.entries.hits[0].objectID).toBe('plural-cat');
	});

	it('load preserves an existing language when the requested dictionary has no entries yet', async () => {
		getDictionaryLanguagesMock.mockResolvedValue({
			en: {
				stopwords: { nbCustomEntries: 2 },
				plurals: null,
				compounds: null
			},
			fr: {
				stopwords: null,
				plurals: { nbCustomEntries: 1 },
				compounds: null
			}
		});
		searchDictionaryEntriesMock.mockResolvedValue({
			hits: [],
			nbHits: 0,
			page: 0,
			nbPages: 0
		});

		const result = (await load(
			makeLoadArgs('?dictionary=plurals&dictionaryLang=en') as never
		)) as LoadResult;

		expect(searchDictionaryEntriesMock).toHaveBeenCalledWith('products', 'plurals', {
			query: '',
			language: 'en'
		});
		expect(result.dictionaries.selectedDictionary).toBe('plurals');
		expect(result.dictionaries.selectedLanguage).toBe('en');
		expect(result.dictionaries.entries).toEqual({
			hits: [],
			nbHits: 0,
			page: 0,
			nbPages: 0
		});
	});

	it('load preserves an explicitly requested language when languages payload is empty', async () => {
		getDictionaryLanguagesMock.mockResolvedValue({});
		searchDictionaryEntriesMock.mockResolvedValue({
			hits: [],
			nbHits: 0,
			page: 0,
			nbPages: 0
		});

		const result = (await load(
			makeLoadArgs('?dictionary=stopwords&dictionaryLang=en') as never
		)) as LoadResult;

		expect(searchDictionaryEntriesMock).toHaveBeenCalledWith('products', 'stopwords', {
			query: '',
			language: 'en'
		});
		expect(result.dictionaries.selectedDictionary).toBe('stopwords');
		expect(result.dictionaries.selectedLanguage).toBe('en');
	});

	it('load falls back to empty dictionaries when fetches fail', async () => {
		getDictionaryLanguagesMock.mockRejectedValue(new Error('languages unavailable'));
		searchDictionaryEntriesMock.mockRejectedValue(new Error('entries unavailable'));

		const result = (await load(makeLoadArgs() as never)) as LoadResult;

		expect(result.dictionaries).toEqual({ ...EMPTY_DICTIONARIES });
	});

	it('load falls back to first available canonical selectors when URL selectors are invalid', async () => {
		getDictionaryLanguagesMock.mockResolvedValue({
			en: {
				stopwords: { nbCustomEntries: 2 },
				plurals: null,
				compounds: null
			},
			fr: {
				stopwords: null,
				plurals: { nbCustomEntries: 1 },
				compounds: null
			}
		});
		const result = (await load(
			makeLoadArgs('?dictionary=invalid&dictionaryLang=zz') as never
		)) as LoadResult;

		expect(result.dictionaries.selectedDictionary).toBe('stopwords');
		expect(result.dictionaries.selectedLanguage).toBe('en');
		expect(searchDictionaryEntriesMock).toHaveBeenCalledWith('products', 'stopwords', {
			query: '',
			language: 'en'
		});
	});

	it('load returns securitySources from api.getSecuritySources()', async () => {
		const sources = {
			sources: [{ source: '192.168.1.0/24', description: 'Office network' }]
		};
		getSecuritySourcesMock.mockResolvedValue(sources);

		const result = (await load(makeLoadArgs() as never)) as LoadResult;

		expect(getSecuritySourcesMock).toHaveBeenCalledWith('products');
		expect(result.securitySources).toEqual(sources);
	});

	it('load retries transient getIndex failures before succeeding', async () => {
		vi.useFakeTimers();
		getIndexMock
			.mockRejectedValueOnce(new ApiRequestError(429, 'Too many requests'))
			.mockResolvedValueOnce({ ...DEFAULT_INDEX });

		const loadPromise = load(makeLoadArgs() as never) as Promise<LoadResult>;
		await vi.runAllTimersAsync();
		const result = await loadPromise;

		expect(getIndexMock).toHaveBeenCalledTimes(2);
		expect(result.index).toEqual({ ...DEFAULT_INDEX });
	});

	it('load falls back to empty securitySources when getSecuritySources fails', async () => {
		getSecuritySourcesMock.mockRejectedValue(new Error('unavailable'));

		const result = (await load(makeLoadArgs() as never)) as LoadResult;

		expect(result.securitySources).toEqual({ ...EMPTY_SECURITY_SOURCES });
	});
});
