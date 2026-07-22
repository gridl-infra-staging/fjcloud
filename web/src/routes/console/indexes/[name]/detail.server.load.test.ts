import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import {
	apiClientFactoryFor,
	createMockFns,
	DEFAULT_INFRASTRUCTURE,
	DEFAULT_INDEX,
	EMPTY_DOCUMENTS,
	EMPTY_DICTIONARIES,
	EMPTY_SECURITY_SOURCES,
	setupDefaultLoadMocks,
	makeLoadArgs
} from './detail.server.test.shared';

const { apiClientFactoryForMock, mocks } = await vi.hoisted(async () => {
	const shared = await import('./detail.server.test.shared');
	return {
		apiClientFactoryForMock: shared.apiClientFactoryFor,
		mocks: shared.createMockFns(vi.fn)
	};
});
const {
	getIndex: getIndexMock,
	getIndexSettings: getIndexSettingsMock,
	browseObjects: browseObjectsMock,
	searchRules: searchRulesMock,
	searchSynonyms: searchSynonymsMock,
	getPersonalizationStrategy: getPersonalizationStrategyMock,
	getQsConfig: getQsConfigMock,
	getQsStatus: getQsStatusMock,
	getAnalyticsTopSearches: getAnalyticsTopSearchesMock,
	getAnalyticsSearchCount: getAnalyticsSearchCountMock,
	getAnalyticsNoResults: getAnalyticsNoResultsMock,
	getAnalyticsNoResultRate: getAnalyticsNoResultRateMock,
	getAnalyticsStatus: getAnalyticsStatusMock,
	getIndexMetrics: getIndexMetricsMock,
	getIndexInfrastructure: getIndexInfrastructureMock,
	getDebugEvents: getDebugEventsMock,
	listExperiments: listExperimentsMock,
	getExperimentResults: getExperimentResultsMock,
	getDictionaryLanguages: getDictionaryLanguagesMock,
	searchDictionaryEntries: searchDictionaryEntriesMock,
	getSecuritySources: getSecuritySourcesMock,
	getIndexes: getIndexesMock
} = mocks;

vi.mock('$lib/server/api', () => apiClientFactoryForMock(mocks, vi.fn));

import { load } from './+page.server';

type LoadResult = Exclude<Awaited<ReturnType<typeof load>>, void>;
type InfrastructureLoadResult = LoadResult & {
	infrastructure?: Record<string, unknown> | null;
	infrastructureError?: { code: number; message: string } | null;
};

describe('Index detail page server -- load', () => {
	it('apiClientFactoryFor throws when a split test leaves an API method unstubbed', () => {
		const isolatedMocks = createMockFns(vi.fn);
		const createApiClient = apiClientFactoryFor(isolatedMocks, vi.fn)
			.createApiClient as unknown as (token: string) => { recommend: () => unknown };
		const api = createApiClient('jwt-token');

		expect(() => api.recommend()).toThrow('Unstubbed $lib/server/api mock: recommend');
	});

	beforeEach(() => {
		vi.clearAllMocks();
		setupDefaultLoadMocks(mocks);
	});

	afterEach(() => {
		vi.useRealTimers();
	});

	it('load fetches rules along with index/settings/replicas/regions', async () => {
		const rulesPayload = {
			hits: [{ objectID: 'boost-shoes', conditions: [], consequence: {} }],
			nbHits: 1,
			page: 0,
			nbPages: 1
		};
		getIndexMock.mockResolvedValue({
			...DEFAULT_INDEX
		});
		getIndexSettingsMock.mockResolvedValue({ searchableAttributes: ['title'] });
		searchRulesMock.mockResolvedValue(rulesPayload);
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

		expect(searchRulesMock).toHaveBeenCalledWith('products', '', 0, 50);
		expect(result.rules).toMatchObject(rulesPayload);
		expect(result.rules.totalNbHits).toBe(1);
		expect(result.rules.query).toBe('');
		expect(result.rules.nbHits).toBe(1);
		expect(result.rules.hits[0].objectID).toBe('boost-shoes');
		expect(result.synonyms.nbHits).toBe(1);
		expect(result.synonyms.hits[0].objectID).toBe('laptop-syn');
		expect(result.personalizationStrategy).toBeNull();
		expect(result.qsConfig?.indexName).toBe('products');
		expect(result.qsStatus?.isRunning).toBe(false);
	});

	it('load fetches rules with URL query and preserves unfiltered total in server payload', async () => {
		searchRulesMock
			.mockResolvedValueOnce({
				hits: [{ objectID: 'boost-shoes', conditions: [], consequence: {} }],
				nbHits: 1,
				page: 0,
				nbPages: 1
			})
			.mockResolvedValueOnce({
				hits: [],
				nbHits: 14,
				page: 0,
				nbPages: 1
			});

		const result = (await load(makeLoadArgs('?q=boost') as never)) as LoadResult;

		expect(searchRulesMock).toHaveBeenNthCalledWith(1, 'products', 'boost', 0, 50);
		expect(searchRulesMock).toHaveBeenNthCalledWith(2, 'products', '', 0, 50);
		expect(result.rules).toMatchObject({
			nbHits: 1,
			totalNbHits: 14,
			query: 'boost'
		});
	});

	it('load keeps filtered rules payload when unfiltered total lookup fails', async () => {
		searchRulesMock
			.mockResolvedValueOnce({
				hits: [{ objectID: 'boost-shoes', conditions: [], consequence: {} }],
				nbHits: 1,
				page: 0,
				nbPages: 1
			})
			.mockRejectedValueOnce(new Error('unfiltered total unavailable'));

		const result = (await load(makeLoadArgs('?q=boost') as never)) as LoadResult;

		expect(searchRulesMock).toHaveBeenNthCalledWith(1, 'products', 'boost', 0, 50);
		expect(searchRulesMock).toHaveBeenNthCalledWith(2, 'products', '', 0, 50);
		expect(result.rules).toMatchObject({
			nbHits: 1,
			totalNbHits: 1,
			query: 'boost'
		});
		expect(result.rules?.hits).toHaveLength(1);
	});

	it('load forwards q query param to synonym search and keeps synonym payload contract stable', async () => {
		searchSynonymsMock.mockResolvedValue({
			hits: [{ objectID: 'laptop-syn', type: 'synonym', synonyms: ['laptop', 'notebook'] }],
			nbHits: 1,
			page: 0,
			nbPages: 1
		});

		const result = (await load(makeLoadArgs('?tab=synonyms&q=laptop') as never)) as LoadResult;

		expect(searchSynonymsMock).toHaveBeenCalledWith('products', 'laptop');
		expect(result.synonyms).toEqual({
			hits: [{ objectID: 'laptop-syn', type: 'synonym', synonyms: ['laptop', 'notebook'] }],
			nbHits: 1,
			page: 0,
			nbPages: 1
		});
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

		const result = (await load(makeLoadArgs('?tab=synonyms&q=laptop') as never)) as LoadResult;

		expect(searchSynonymsMock).toHaveBeenCalledWith('products', 'laptop');
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

		const result = (await load(makeLoadArgs('?dict=plurals&lang=fr') as never)) as LoadResult;

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

		const result = (await load(makeLoadArgs('?dict=plurals&lang=en') as never)) as LoadResult;

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

		const result = (await load(makeLoadArgs('?dict=stopwords&lang=en') as never)) as LoadResult;

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
		const result = (await load(makeLoadArgs('?dict=invalid&lang=zz') as never)) as LoadResult;

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
		expect((result as Record<string, unknown>).securitySourcesLoadError).toBe('unavailable');
	});

	it('load marks initial debug events fetch failure as eventsLoadError', async () => {
		getDebugEventsMock.mockRejectedValue(new Error('events unavailable'));

		const result = (await load(makeLoadArgs() as never)) as LoadResult;

		expect(result.debugEvents).toBeNull();
		expect((result as Record<string, unknown>).eventsLoadError).toBe('events unavailable');
		expect((result as Record<string, unknown>).eventsError).toBeUndefined();
	});

	it('load populates allIndexes from getIndexes on success', async () => {
		const indexes = [{ ...DEFAULT_INDEX }, { ...DEFAULT_INDEX, name: 'products_v2' }];
		getIndexesMock.mockResolvedValue(indexes);

		const result = (await load(makeLoadArgs() as never)) as LoadResult;

		expect((result as Record<string, unknown>).allIndexes).toEqual(indexes);
	});

	it('load falls back to empty array when getIndexes fails', async () => {
		getIndexesMock.mockRejectedValue(new Error('forbidden'));

		const result = (await load(makeLoadArgs() as never)) as LoadResult;

		expect((result as Record<string, unknown>).allIndexes).toEqual([]);
	});

	it('load returns metrics payload alongside existing detail payload for metrics tab route', async () => {
		const dependsSpy = vi.fn();
		const result = (await load(
			makeLoadArgs('?tab=metrics', { depends: dependsSpy }) as never
		)) as LoadResult & {
			metrics?: Record<string, unknown>;
			metricsError?: Record<string, unknown> | null;
		};

		expect(result.index).toEqual({ ...DEFAULT_INDEX });
		expect(result.documents).toEqual({ ...EMPTY_DOCUMENTS });
		expect(result.metrics).toEqual({
			index: 'products',
			documents_count: 0,
			storage_bytes: 0,
			search_requests_total: 0,
			write_operations_total: 0,
			fetched_at: '2026-03-01T10:00:00Z'
		});
		expect(result.metricsError).toBeNull();
		expect(dependsSpy).toHaveBeenCalledWith('app:index-metrics:products');
	});

	it('load keeps base detail payload when metrics loading fails and exposes metricsError', async () => {
		getIndexMetricsMock.mockRejectedValue(new ApiRequestError(503, 'metrics fetch unavailable'));

		const result = (await load(makeLoadArgs('?tab=metrics') as never)) as LoadResult & {
			metrics?: Record<string, unknown> | null;
			metricsError?: { code: number; message: string } | null;
		};

		expect(result.index.name).toBe('products');
		expect(result.rules).not.toBeNull();
		expect(result.documents).toEqual({ ...EMPTY_DOCUMENTS });
		expect(result.metrics).toBeNull();
		expect(result.metricsError).toEqual({
			code: 503,
			message: 'Metrics service unavailable'
		});
	});

	it('load does not leak raw authorization error details in metricsError', async () => {
		getIndexMetricsMock.mockRejectedValue(
			new ApiRequestError(403, 'tenant 42 cannot access shard 7')
		);

		const result = (await load(makeLoadArgs('?tab=metrics') as never)) as LoadResult & {
			metrics?: Record<string, unknown> | null;
			metricsError?: { code: number; message: string } | null;
		};

		expect(result.metrics).toBeNull();
		expect(result.metricsError).toEqual({
			code: 403,
			message: 'You are not authorized to view metrics for this index'
		});
	});

	it('load returns infrastructure alongside the existing detail payload and dependency key', async () => {
		const dependsSpy = vi.fn();

		const result = (await load(
			makeLoadArgs('', { depends: dependsSpy }) as never
		)) as InfrastructureLoadResult;

		expect(getIndexInfrastructureMock).toHaveBeenCalledWith('products');
		expect(result.index).toEqual({ ...DEFAULT_INDEX });
		expect(result.documents).toEqual({ ...EMPTY_DOCUMENTS });
		expect(result.infrastructure).toEqual(DEFAULT_INFRASTRUCTURE);
		expect(result.infrastructureError).toBeNull();
		expect(dependsSpy).toHaveBeenCalledWith('app:index-infrastructure:products');
	});

	it.each([
		{
			status: 401,
			expectedMessage: 'You are not authorized to view infrastructure for this index'
		},
		{
			status: 403,
			expectedMessage: 'You are not authorized to view infrastructure for this index'
		},
		{ status: 404, expectedMessage: 'Infrastructure is not available for this index yet' },
		{ status: 429, expectedMessage: 'Infrastructure is temporarily unavailable' },
		{ status: 503, expectedMessage: 'Infrastructure service unavailable' }
	])(
		'load maps Infrastructure $status failures without exposing backend details',
		async ({ status, expectedMessage }) => {
			const rawDetail = `tenant cust-1 infrastructure detail for ${status}`;
			getIndexInfrastructureMock.mockRejectedValue(new ApiRequestError(status, rawDetail));

			const result = (await load(makeLoadArgs() as never)) as InfrastructureLoadResult;

			expect(result.index).toEqual({ ...DEFAULT_INDEX });
			expect(result.rules).not.toBeNull();
			expect(result.documents).toEqual({ ...EMPTY_DOCUMENTS });
			expect(result.infrastructure).toBeNull();
			expect(result.infrastructureError).toEqual({ code: status, message: expectedMessage });
			expect(result.infrastructureError?.message).not.toContain(rawDetail);
		}
	);

	it('load maps unexpected Infrastructure failures to a fixed generic 503 error', async () => {
		const rawDetail = 'socket exposed internal host vm-123';
		getIndexInfrastructureMock.mockRejectedValue(new Error(rawDetail));

		const result = (await load(makeLoadArgs() as never)) as InfrastructureLoadResult;

		expect(result.index).toEqual({ ...DEFAULT_INDEX });
		expect(result.infrastructure).toBeNull();
		expect(result.infrastructureError).toEqual({
			code: 503,
			message: 'Infrastructure service unavailable'
		});
		expect(result.infrastructureError?.message).not.toContain(rawDetail);
	});
});
