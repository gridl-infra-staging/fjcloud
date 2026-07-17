// Dictionary API types extracted from types.ts to keep that barrel file
// under the 800-line size cap enforced by scripts/check-sizes.sh. These
// types are used by the index-detail dictionary editor surfaces and by
// the Flapjack proxy contract for stopwords/plurals/compounds management.

export type DictionaryName = 'stopwords' | 'plurals' | 'compounds';

export interface DictionaryCount {
	nbCustomEntries: number;
}

export interface LanguageDictionaryCounts {
	stopwords: DictionaryCount | null;
	plurals: DictionaryCount | null;
	compounds: DictionaryCount | null;
}

export type DictionaryLanguagesResponse = Record<string, LanguageDictionaryCounts>;

export interface DictionaryEntry {
	objectID: string;
	language: string;
	word?: string;
	words?: string[];
	decomposition?: string[];
	state?: string;
	[key: string]: unknown;
}

export interface DictionarySearchRequest {
	query: string;
	language?: string;
	page?: number;
	hitsPerPage?: number;
}

export interface DictionarySearchResponse {
	hits: DictionaryEntry[];
	nbHits: number;
	page: number;
	nbPages: number;
}

export type DictionaryBatchAction = 'addEntry' | 'deleteEntry';

export interface DictionaryBatchOperation {
	action: DictionaryBatchAction;
	body: Record<string, unknown>;
}

export interface DictionaryBatchRequest {
	clearExistingDictionaryEntries?: boolean;
	requests: DictionaryBatchOperation[];
}

export interface DictionaryBatchResponse {
	taskID: number;
	updatedAt: string;
	[key: string]: unknown;
}
