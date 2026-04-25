// Algolia migration API types extracted from types.ts to keep the barrel
// file under the 800-line size cap. Used by the migrate-from-algolia
// dashboard surface and the corresponding admin proxy endpoints.

export interface AlgoliaIndexInfo {
	name: string;
	entries: number;
	lastBuildTimeS: number;
}

export interface AlgoliaIndexListResponse {
	indexes: AlgoliaIndexInfo[];
}

export interface AlgoliaListRequest {
	appId: string;
	apiKey: string;
}

export interface AlgoliaMigrateRequest {
	appId: string;
	apiKey: string;
	sourceIndex: string;
}

export interface AlgoliaMigrateResponse {
	taskId: string;
	message: string;
}
