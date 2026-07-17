// Recommendations batch request/response types (Algolia-parity Recommend).

export interface RecommendationRequest {
	indexName: string;
	model: string;
	objectID?: string;
	threshold?: number;
	maxRecommendations?: number;
	facetName?: string;
	facetValue?: string;
	queryParameters?: Record<string, unknown>;
	fallbackParameters?: Record<string, unknown>;
}

export interface RecommendationsBatchRequest {
	requests: RecommendationRequest[];
}

export interface RecommendationsResult {
	hits: Record<string, unknown>[];
	processingTimeMS: number;
}

export interface RecommendationsBatchResponse {
	results: RecommendationsResult[];
}
