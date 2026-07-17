// Query Suggestions (Qs) configuration and build status types.

export interface QsFacet {
	attribute: string;
	amount: number;
}

export interface QsSourceIndex {
	indexName: string;
	minHits: number;
	minLetters: number;
	facets: QsFacet[];
	generate: string[][];
	analyticsTags: string[];
	replicas: boolean;
}

export interface QsConfig {
	indexName: string;
	sourceIndices: QsSourceIndex[];
	languages: string[];
	exclude: string[];
	allowSpecialCharacters: boolean;
	enablePersonalization: boolean;
}

export interface QsBuildStatus {
	indexName: string;
	isRunning: boolean;
	lastBuiltAt: string | null;
	lastSuccessfulBuiltAt: string | null;
}
