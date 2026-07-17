// Query rule types (Algolia-parity rules editor / search).

export interface RuleCondition {
	pattern?: string;
	anchoring?: string;
	alternatives?: boolean;
	context?: string;
	filters?: string;
	[key: string]: unknown;
}

export interface RuleConsequence {
	promote?: Record<string, unknown>[];
	hide?: Record<string, unknown>[];
	filterPromotes?: boolean;
	userData?: Record<string, unknown>;
	params?: Record<string, unknown>;
	[key: string]: unknown;
}

export interface RuleValidityRange {
	from: number;
	until: number;
}

export interface Rule {
	objectID: string;
	conditions: RuleCondition[];
	consequence: RuleConsequence;
	description?: string;
	enabled?: boolean;
	validity?: RuleValidityRange[];
}

export interface RuleSearchResponse {
	hits: Rule[];
	nbHits: number;
	page: number;
	nbPages: number;
}
