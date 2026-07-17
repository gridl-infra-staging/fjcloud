// Algolia migration API types extracted from types.ts to keep the barrel
// file under the 800-line size cap.

export interface AlgoliaMigrationAvailabilityResponse {
	available: boolean;
	reason: 'temporarily_unavailable';
	message: string;
}

export interface ListAlgoliaIndexesRequest {
	appId: string;
	apiKey: string;
	cursor?: string | null;
}

export interface AlgoliaIndexMetadata {
	name: string;
	entries: number;
	dataSize: number;
	fileSize: number;
	updatedAt: string;
	lastBuildTimeS: number;
	pendingTask: boolean;
	primary: string | null;
	replicas: string[];
}

export interface AlgoliaSourceListResponse {
	items: AlgoliaIndexMetadata[];
	nextCursor: string | null;
}
