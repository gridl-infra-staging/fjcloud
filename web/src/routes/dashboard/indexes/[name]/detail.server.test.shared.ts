/**
 * Shared mock references, helper functions, and constants for detail.server tests.
 *
 * IMPORTANT: Each test file must declare its own top-level vi.mock() calls.
 * This module only exports the mock function references and helpers -- it does NOT
 * call vi.mock() itself.
 */
import type { vi as ViType } from 'vitest';

// ---------------------------------------------------------------------------
// Mock function references
//
// Each test file creates its own vi.fn() instances and passes them here via
// createMockFns(). This avoids sharing mutable state across files while still
// letting helpers reference the mocks.
// ---------------------------------------------------------------------------

export interface MockFns {
	getIndex: ReturnType<typeof ViType.fn>;
	getIndexSettings: ReturnType<typeof ViType.fn>;
	listReplicas: ReturnType<typeof ViType.fn>;
	getInternalRegions: ReturnType<typeof ViType.fn>;
	addObjects: ReturnType<typeof ViType.fn>;
	browseObjects: ReturnType<typeof ViType.fn>;
	deleteObject: ReturnType<typeof ViType.fn>;
	searchRules: ReturnType<typeof ViType.fn>;
	searchSynonyms: ReturnType<typeof ViType.fn>;
	getPersonalizationStrategy: ReturnType<typeof ViType.fn>;
	savePersonalizationStrategy: ReturnType<typeof ViType.fn>;
	deletePersonalizationStrategy: ReturnType<typeof ViType.fn>;
	getPersonalizationProfile: ReturnType<typeof ViType.fn>;
	deletePersonalizationProfile: ReturnType<typeof ViType.fn>;
	getQsConfig: ReturnType<typeof ViType.fn>;
	getQsStatus: ReturnType<typeof ViType.fn>;
	getAnalyticsTopSearches: ReturnType<typeof ViType.fn>;
	getAnalyticsSearchCount: ReturnType<typeof ViType.fn>;
	getAnalyticsNoResults: ReturnType<typeof ViType.fn>;
	getAnalyticsNoResultRate: ReturnType<typeof ViType.fn>;
	getAnalyticsStatus: ReturnType<typeof ViType.fn>;
	getDebugEvents: ReturnType<typeof ViType.fn>;
	listExperiments: ReturnType<typeof ViType.fn>;
	createExperiment: ReturnType<typeof ViType.fn>;
	deleteExperiment: ReturnType<typeof ViType.fn>;
	startExperiment: ReturnType<typeof ViType.fn>;
	stopExperiment: ReturnType<typeof ViType.fn>;
	concludeExperiment: ReturnType<typeof ViType.fn>;
	getExperimentResults: ReturnType<typeof ViType.fn>;
	updateIndexSettings: ReturnType<typeof ViType.fn>;
	saveRule: ReturnType<typeof ViType.fn>;
	deleteRule: ReturnType<typeof ViType.fn>;
	saveSynonym: ReturnType<typeof ViType.fn>;
	deleteSynonym: ReturnType<typeof ViType.fn>;
	saveQsConfig: ReturnType<typeof ViType.fn>;
	deleteQsConfig: ReturnType<typeof ViType.fn>;
	getDictionaryLanguages: ReturnType<typeof ViType.fn>;
	searchDictionaryEntries: ReturnType<typeof ViType.fn>;
	batchDictionaryEntries: ReturnType<typeof ViType.fn>;
	getSecuritySources: ReturnType<typeof ViType.fn>;
	appendSecuritySource: ReturnType<typeof ViType.fn>;
	deleteSecuritySource: ReturnType<typeof ViType.fn>;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

export const DEFAULT_INDEX = {
	name: 'products',
	region: 'us-east-1',
	endpoint: null,
	entries: 0,
	data_size_bytes: 0,
	status: 'ready',
	tier: 'active',
	created_at: '2026-02-25T00:00:00Z'
} as const;

export const EMPTY_RULES = { hits: [], nbHits: 0, page: 0, nbPages: 0 } as const;
export const EMPTY_SYNONYMS = { hits: [], nbHits: 0 } as const;
export const EMPTY_EXPERIMENTS = { abtests: [], count: 0, total: 0 } as const;
export const EMPTY_DICTIONARY_ENTRIES = {
	hits: [],
	nbHits: 0,
	page: 0,
	nbPages: 0
} as const;

export const EMPTY_DICTIONARIES = {
	languages: null,
	selectedDictionary: 'stopwords',
	selectedLanguage: '',
	entries: EMPTY_DICTIONARY_ENTRIES
} as const;

export const EMPTY_SECURITY_SOURCES = { sources: [] } as const;

export const EMPTY_DOCUMENTS = {
	hits: [],
	cursor: null,
	nbHits: 0,
	page: 0,
	nbPages: 0,
	hitsPerPage: 20,
	query: '',
	params: ''
} as const;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Sets up all load-related mocks with sensible defaults so each test only
 * needs to override the mocks it cares about.
 */
export function setupDefaultLoadMocks(m: MockFns): void {
	m.getIndex.mockResolvedValue({ ...DEFAULT_INDEX });
	m.getIndexSettings.mockResolvedValue({});
	m.listReplicas.mockResolvedValue([]);
	m.getInternalRegions.mockResolvedValue([]);
	m.addObjects.mockResolvedValue({ taskID: 99, objectIDs: [] });
	m.browseObjects.mockResolvedValue({ ...EMPTY_DOCUMENTS });
	m.deleteObject.mockResolvedValue({ taskID: 101, deletedAt: '2026-03-18T12:00:00Z' });
	m.searchRules.mockResolvedValue({ ...EMPTY_RULES });
	m.searchSynonyms.mockResolvedValue({ ...EMPTY_SYNONYMS });
	m.getPersonalizationStrategy.mockResolvedValue(null);
	m.getQsConfig.mockResolvedValue(null);
	m.getQsStatus.mockResolvedValue(null);
	m.getAnalyticsTopSearches.mockResolvedValue({ searches: [] });
	m.getAnalyticsSearchCount.mockResolvedValue({ count: 1234, dates: [] });
	m.getAnalyticsNoResults.mockResolvedValue({ searches: [] });
	m.getAnalyticsNoResultRate.mockResolvedValue({
		rate: 0.12,
		count: 1234,
		noResults: 148,
		dates: []
	});
	m.getAnalyticsStatus.mockResolvedValue({ indexName: 'products', enabled: true });
	m.listExperiments.mockResolvedValue({ ...EMPTY_EXPERIMENTS });
	m.getDebugEvents.mockResolvedValue({ events: [], count: 0 });
	m.getDictionaryLanguages.mockResolvedValue(null);
	m.searchDictionaryEntries.mockResolvedValue({ ...EMPTY_DICTIONARY_ENTRIES });
	m.batchDictionaryEntries.mockResolvedValue({ taskID: 0, updatedAt: '' });
	m.getSecuritySources.mockResolvedValue({ ...EMPTY_SECURITY_SOURCES });
	m.appendSecuritySource.mockResolvedValue({ createdAt: '2026-03-19T00:00:00Z' });
	m.deleteSecuritySource.mockResolvedValue({ deletedAt: '2026-03-19T00:00:00Z' });
}

/** Creates the standard load() call arguments for the 'products' index. */
export function makeLoadArgs(urlSuffix = ''): unknown {
	return {
		locals: { user: { customerId: 'cust-1', token: 'jwt-token' } },
		params: { name: 'products' },
		url: new URL(`http://localhost/dashboard/indexes/products${urlSuffix}`)
	} as never;
}

/** Creates the standard action call arguments. */
export function makeActionArgs(actionName: string, formData: FormData): unknown {
	return {
		request: new Request(
			`http://localhost/dashboard/indexes/products?/${actionName}`,
			{ method: 'POST', body: formData }
		),
		locals: { user: { customerId: 'cust-1', token: 'jwt-token' } },
		params: { name: 'products' }
	} as never;
}
