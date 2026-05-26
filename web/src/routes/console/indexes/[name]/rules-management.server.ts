import { fail } from '@sveltejs/kit';
import { createApiClient } from '$lib/server/api';
import { mapDashboardSessionFailure } from '$lib/server/auth-action-errors';
import { errorMessage, parseJsonObject } from './document-management.server';
import type { Rule, RuleSearchResponse } from '$lib/api/types';

type RulesActionArgs = {
	request: Request;
	indexName: string;
	token: string | undefined;
};

function failForRulesAction<T extends Record<string, unknown>>(error: unknown, payload: T) {
	const sessionFailure = mapDashboardSessionFailure(error);
	if (sessionFailure) return sessionFailure;
	return fail(400, payload);
}

function extractRuleObjectIds(rules: RuleSearchResponse | null): string[] {
	if (!rules || !Array.isArray(rules.hits)) return [];
	return rules.hits
		.map((rule) => (typeof rule?.objectID === 'string' ? rule.objectID.trim() : ''))
		.filter((objectID) => objectID.length > 0);
}

export async function loadRulesPayload(api: ReturnType<typeof createApiClient>, indexName: string) {
	return loadRulesPayloadForQuery(api, indexName, '');
}

type RuleLoadPayload = (RuleSearchResponse & { totalNbHits: number; query: string }) | null;

export async function loadRulesPayloadForQuery(
	api: ReturnType<typeof createApiClient>,
	indexName: string,
	query: string
): Promise<RuleLoadPayload> {
	const normalizedQuery = query.trim();

	try {
		if (normalizedQuery.length === 0) {
			const rules = await api.searchRules(indexName, '', 0, 50);
			return {
				...rules,
				totalNbHits: rules.nbHits,
				query: ''
			};
		}

		const filteredRules = await api.searchRules(indexName, normalizedQuery, 0, 50);
		let totalNbHits = filteredRules.nbHits;
		try {
			const allRules = await api.searchRules(indexName, '', 0, 50);
			totalNbHits = allRules.nbHits;
		} catch {
			totalNbHits = filteredRules.nbHits;
		}
		return {
			...filteredRules,
			totalNbHits,
			query: normalizedQuery
		};
	} catch {
		return null;
	}
}

export async function saveRuleAction({ request, indexName, token }: RulesActionArgs) {
	const data = await request.formData();
	const objectID = (data.get('objectID') as string)?.trim();
	const rawRule = (data.get('rule') as string)?.trim();
	if (!objectID) return fail(400, { ruleError: 'objectID is required' });
	if (!rawRule) return fail(400, { ruleError: 'Rule JSON is required' });

	let rule: Rule;
	try {
		rule = parseJsonObject<Rule>(rawRule, 'rule');
	} catch (error) {
		return failForRulesAction(error, { ruleError: errorMessage(error, 'Invalid rule JSON') });
	}

	const api = createApiClient(token);
	try {
		await api.saveRule(indexName, objectID, rule);
		return { ruleSaved: true };
	} catch (error) {
		return failForRulesAction(error, { ruleError: errorMessage(error, 'Failed to save rule') });
	}
}

export async function deleteRuleAction({ request, indexName, token }: RulesActionArgs) {
	const data = await request.formData();
	const objectID = (data.get('objectID') as string)?.trim();
	if (!objectID) return fail(400, { ruleError: 'objectID is required' });

	const api = createApiClient(token);
	try {
		await api.deleteRule(indexName, objectID);
		return { ruleDeleted: true };
	} catch (error) {
		return failForRulesAction(error, { ruleError: errorMessage(error, 'Failed to delete rule') });
	}
}

export async function clearRulesAction({ indexName, token }: Omit<RulesActionArgs, 'request'>) {
	const api = createApiClient(token);
	const requestedDeletes = new Set<string>();
	try {
		while (true) {
			const rulesPage = await api.searchRules(indexName);
			const ruleObjectIds = extractRuleObjectIds(rulesPage);
			if (ruleObjectIds.length === 0) {
				return { rulesCleared: true };
			}

			for (const objectID of ruleObjectIds) {
				if (requestedDeletes.has(objectID)) {
					continue;
				}
				await api.deleteRule(indexName, objectID);
				requestedDeletes.add(objectID);
			}
		}
	} catch (error) {
		return failForRulesAction(error, {
			rulesClearError: errorMessage(error, 'Failed to clear rules')
		});
	}
}
