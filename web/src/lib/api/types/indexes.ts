// Customer-facing index management, document, search, and browse types (Stage 5).

export interface Index {
	name: string;
	region: string;
	endpoint: string | null;
	entries: number;
	data_size_bytes: number;
	status: string;
	tier: string;
	created_at: string;
}

export interface CreateIndexRequest {
	name: string;
	region: string;
}

export interface InternalRegion {
	id: string;
	provider: string;
	provider_location: string;
	display_name: string;
	available: boolean;
}

export type CreateIndexResponse = Index;

export interface SearchResult {
	hits: unknown[];
	nbHits: number;
	processingTimeMs?: number;
	facets?: Record<string, Record<string, number>>;
	queryID?: string;
	/** Extra metadata forwarded from the search engine (page, hitsPerPage, facets, etc.). */
	[key: string]: unknown;
}

export interface PreviewEventRequest {
	eventName: 'search_preview_result_opened';
	objectID: string;
	position: number;
	queryID: string;
	timestamp: number;
	userToken: string;
}

export type DocumentBatchAction =
	| 'addObject'
	| 'updateObject'
	| 'deleteObject'
	| 'partialUpdateObject';

export interface DocumentBatchOperation {
	action: DocumentBatchAction;
	indexName?: string;
	body?: Record<string, unknown>;
	createIfNotExists?: boolean;
}

export interface AddObjectsRequest {
	requests: DocumentBatchOperation[];
}

export interface AddObjectsResponse {
	taskID: number;
	objectIDs?: string[];
	[key: string]: unknown;
}

export interface BrowseObjectsRequest {
	cursor?: string;
	query?: string;
	filters?: string;
	hitsPerPage?: number;
	attributesToRetrieve?: string[];
	params?: string;
}

export interface BrowseObjectsResponse {
	hits: Record<string, unknown>[];
	cursor: string | null;
	nbHits: number;
	page: number;
	nbPages: number;
	hitsPerPage: number;
	query: string;
	params: string;
	[key: string]: unknown;
}

// Multi-region read replica summary.
export interface IndexReplicaSummary {
	id: string;
	replica_region: string;
	status: string;
	lag_ops: number;
	endpoint: string;
	created_at: string;
}

// Mirrors infra/api/src/state.rs::CustomerIndexMetricsResponse; Rust uses u64,
// but paid-beta values stay safely within JS number precision here.
export interface IndexMetricsResponse {
	index: string;
	documents_count: number;
	storage_bytes: number;
	search_requests_total: number;
	write_operations_total: number;
	fetched_at: string;
}
