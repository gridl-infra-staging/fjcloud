import type {
	DictionaryName,
	Index,
	IndexReplicaSummary,
	InternalRegion,
	SynonymSearchResponse
} from '$lib/api/types';
import { layoutTestDefaults } from '../../layout-test-context';

export const sampleIndex: Index = {
	name: 'products',
	region: 'us-east-1',
	endpoint: 'https://vm-abc.flapjack.foo',
	entries: 1500,
	data_size_bytes: 204800,
	status: 'ready',
	tier: 'active',
	created_at: '2026-02-15T10:00:00Z'
};

export const sampleSettings = {
	searchableAttributes: ['title', 'description'],
	displayedAttributes: ['*'],
	filterableAttributes: ['category'],
	sortableAttributes: ['price']
};

export const sampleRules = {
	hits: [
		{
			objectID: 'boost-shoes',
			conditions: [{ pattern: 'shoes', anchoring: 'contains' }],
			consequence: { promote: [{ objectID: 'shoe-1', position: 0 }] },
			description: 'Boost shoes',
			enabled: true
		}
	],
	nbHits: 1,
	page: 0,
	nbPages: 1
};

export const sampleSynonyms: SynonymSearchResponse = {
	hits: [
		{
			objectID: 'laptop-syn',
			type: 'synonym',
			synonyms: ['laptop', 'notebook', 'computer']
		}
	],
	nbHits: 1
};

export const samplePersonalizationStrategy = {
	eventsScoring: [
		{ eventName: 'Product viewed', eventType: 'view' as const, score: 10 },
		{ eventName: 'Product purchased', eventType: 'conversion' as const, score: 50 }
	],
	facetsScoring: [
		{ facetName: 'brand', score: 70 },
		{ facetName: 'category', score: 30 }
	],
	personalizationImpact: 75
};

export const samplePersonalizationProfile = {
	userToken: 'user_abc',
	scores: {
		brand: { apple: 20 },
		category: { shoes: 12 }
	},
	lastEventAt: '2026-02-25T00:00:00Z'
};

export const sampleQsConfig = {
	indexName: 'products',
	sourceIndices: [
		{
			indexName: 'products',
			minHits: 5,
			minLetters: 4,
			facets: [],
			generate: [],
			analyticsTags: [],
			replicas: false
		}
	],
	languages: ['en'],
	exclude: [],
	allowSpecialCharacters: false,
	enablePersonalization: false
};

export const sampleQsStatus = {
	indexName: 'products',
	isRunning: false,
	lastBuiltAt: '2026-02-25T06:00:00Z',
	lastSuccessfulBuiltAt: '2026-02-25T06:00:00Z'
};

export const sampleSearchCount = {
	count: 1234,
	dates: [
		{ date: '2026-02-23', count: 170 },
		{ date: '2026-02-24', count: 180 },
		{ date: '2026-02-25', count: 210 }
	]
};

export const sampleNoResultRate = {
	rate: 0.12,
	count: 1234,
	noResults: 148,
	dates: [
		{ date: '2026-02-23', rate: 0.1, count: 170, noResults: 17 },
		{ date: '2026-02-24', rate: 0.11, count: 180, noResults: 20 },
		{ date: '2026-02-25', rate: 0.13, count: 210, noResults: 27 }
	]
};

export const sampleTopSearches = {
	searches: [
		{ search: 'laptop', count: 42, nbHits: 15 },
		{ search: 'iphone', count: 30, nbHits: 22 }
	]
};

export const sampleNoResults = {
	searches: [
		{ search: 'lapptop', count: 8, nbHits: 0 },
		{ search: 'iphnoe', count: 5, nbHits: 0 }
	]
};

export const sampleAnalyticsStatus = {
	indexName: 'products',
	enabled: true
};

export const sampleDocuments = {
	hits: [
		{
			objectID: 'doc-1',
			title: 'First Document',
			category: 'guides'
		}
	],
	cursor: 'next-cursor',
	nbHits: 1,
	page: 0,
	nbPages: 1,
	hitsPerPage: 20,
	query: '',
	params: ''
};

export const sampleDictionaries = {
	languages: {
		en: {
			stopwords: { nbCustomEntries: 2 },
			plurals: null,
			compounds: null
		}
	},
	selectedDictionary: 'stopwords' as DictionaryName,
	selectedLanguage: 'en',
	entries: {
		hits: [{ objectID: 'stop-the', language: 'en', word: 'the', state: 'enabled' }],
		nbHits: 1,
		page: 0,
		nbPages: 1
	}
};

export const sampleExperiments = {
	abtests: [
		{
			abTestID: 7,
			name: 'Ranking test',
			status: 'running',
			endAt: '2026-03-15T00:00:00Z',
			createdAt: '2026-02-25T00:00:00Z',
			updatedAt: '2026-02-25T00:00:00Z',
			variants: [
				{ index: 'products', trafficPercentage: 50 },
				{ index: 'products', trafficPercentage: 50, customSearchParameters: { enableRules: false } }
			],
			configuration: {}
		},
		{
			abTestID: 9,
			name: 'Stopped test',
			status: 'stopped',
			endAt: '2026-03-20T00:00:00Z',
			createdAt: '2026-02-24T00:00:00Z',
			updatedAt: '2026-02-25T00:00:00Z',
			variants: [{ index: 'products', trafficPercentage: 50 }],
			configuration: {}
		}
	],
	count: 2,
	total: 2
};

export const sampleExperimentResults = {
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
	significance: {
		zScore: 2.1,
		pValue: 0.03,
		confidence: 0.97,
		significant: true,
		relativeImprovement: 0.08,
		winner: 'variant'
	},
	sampleRatioMismatch: false,
	guardRailAlerts: [],
	cupedApplied: true
};

export const sampleExperimentResultsNotReady = {
	...sampleExperimentResults,
	gate: {
		...sampleExperimentResults.gate,
		readyToRead: false,
		progressPct: 42,
		currentSearchesPerArm: 420,
		requiredSearchesPerArm: 1000,
		estimatedDaysRemaining: 3
	}
};

export const sampleConcludedExperimentResults = {
	...sampleExperimentResults,
	status: 'concluded',
	significance: {
		...sampleExperimentResults.significance,
		winner: 'variant',
		confidence: 0.98
	},
	recommendation: 'Variant has higher CTR and should be promoted'
};

export const sampleReplicas: IndexReplicaSummary[] = [
	{
		id: 'aaaaaaaa-1111-2222-3333-444444444444',
		replica_region: 'eu-central-1',
		status: 'active',
		lag_ops: 12,
		endpoint: 'http://vm-replica-eu.flapjack.foo:7700',
		created_at: '2026-02-18T14:00:00Z'
	}
];

export const sampleRegions: InternalRegion[] = [
	{
		id: 'us-east-1',
		provider: 'aws',
		provider_location: 'us-east-1',
		display_name: 'US East (Virginia)',
		available: true
	},
	{
		id: 'eu-central-1',
		provider: 'hetzner',
		provider_location: 'fsn1',
		display_name: 'EU Central (Germany)',
		available: true
	},
	{
		id: 'eu-north-1',
		provider: 'hetzner',
		provider_location: 'hel1',
		display_name: 'EU North (Helsinki)',
		available: true
	}
];

export const sampleDebugEvents = {
	events: [
		{
			timestampMs: 1709251200000,
			index: 'products',
			eventType: 'view',
			eventSubtype: null,
			eventName: 'Viewed Product',
			userToken: 'user_abc',
			objectIds: ['obj1', 'obj2'],
			httpCode: 200,
			validationErrors: []
		},
		{
			timestampMs: 1709251260000,
			index: 'products',
			eventType: 'click',
			eventSubtype: null,
			eventName: 'Clicked Result',
			userToken: 'user_def',
			objectIds: ['obj3'],
			httpCode: 400,
			validationErrors: ['missing objectID']
		}
	],
	count: 2
};

export const sampleSecuritySources = {
	sources: [
		{ source: '192.168.1.0/24', description: 'Office network' },
		{ source: '10.0.0.0/8', description: 'VPN range' }
	]
};

export function createMockPageData(overrides: Record<string, unknown> = {}) {
	return {
		user: null,
		...layoutTestDefaults,
		index: sampleIndex,
		settings: sampleSettings,
		replicas: [],
		regions: [],
		rules: sampleRules,
		synonyms: sampleSynonyms,
		personalizationStrategy: samplePersonalizationStrategy,
		qsConfig: sampleQsConfig,
		qsStatus: sampleQsStatus,
		searchCount: sampleSearchCount,
		noResultRate: sampleNoResultRate,
		topSearches: sampleTopSearches,
		noResults: sampleNoResults,
		analyticsStatus: sampleAnalyticsStatus,
		analyticsPeriod: '7d' as const,
		documents: sampleDocuments,
		experiments: sampleExperiments,
		experimentResults: { '7': sampleExperimentResults },
		debugEvents: null,
		dictionaries: sampleDictionaries,
		securitySources: sampleSecuritySources,
		...overrides
	};
}
