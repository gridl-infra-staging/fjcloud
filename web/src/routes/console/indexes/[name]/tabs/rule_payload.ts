import type { RuleSearchResponse } from '$lib/api/types';

export type RuleListPayload = RuleSearchResponse & {
	totalNbHits?: number;
	query?: string;
};
