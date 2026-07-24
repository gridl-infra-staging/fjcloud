import type { Rule, RuleCondition, RuleValidityRange } from '$lib/api/types';

export interface ParseRuleEditorJsonResult {
	rule?: Rule;
	error?: string;
}

export interface PrepareRuleEditorSaveResult extends ParseRuleEditorJsonResult {
	json?: string;
}

type RulePromote = Record<string, unknown>;
type RuleHide = Record<string, unknown>;

export interface RuleRowStatus {
	isDraft: boolean;
	label: 'Active' | 'Draft';
}

export type RuleEditorState = 'draft' | 'published';

export interface RuleConsequenceBuilderInput {
	promoteObjectID?: string;
	promotePosition?: number | string | null;
	hideObjectID?: string;
}

export interface RuleBuilderInput extends RuleConsequenceBuilderInput {
	objectID: string;
	description?: string;
	state: RuleEditorState;
	queryPattern: string;
	anchoring: string;
	filterScope?: string;
	validFrom?: string;
	validUntil?: string;
}

interface CreateMerchandisingRuleInput {
	query: string;
	description?: string;
	pins: RulePromote[];
	hides: RuleHide[];
	timestamp?: number;
}

function slugify(input: string): string {
	const slug = input
		.trim()
		.toLowerCase()
		.replace(/[^a-z0-9]+/g, '-')
		.replace(/^-+|-+$/g, '');

	return slug || 'query';
}

function normalizeRuleScopeValue(value: unknown): string {
	return typeof value === 'string' ? value.trim().toLowerCase() : '';
}

function buildRuleConflictScope(rule: Rule): string | null {
	const condition = rule.conditions[0];
	if (!condition) return null;

	const pattern = normalizeRuleScopeValue(condition.pattern);
	if (!pattern) return null;
	return [
		pattern,
		normalizeRuleScopeValue(condition.anchoring),
		normalizeRuleScopeValue(condition.filters)
	].join('\u0000');
}

export function buildRuleRowStatus(rule: Rule): RuleRowStatus {
	const isDraft = rule.enabled === false;
	return {
		isDraft,
		label: isDraft ? 'Draft' : 'Active'
	};
}

export function buildRuleConflictMap(rules: Rule[]): Map<string, boolean> {
	const scopeCounts = new Map<string, number>();
	const ruleScopes = new Map<string, string | null>();

	for (const rule of rules) {
		const scope = buildRuleConflictScope(rule);
		ruleScopes.set(rule.objectID, scope);
		if (scope !== null) {
			scopeCounts.set(scope, (scopeCounts.get(scope) ?? 0) + 1);
		}
	}

	return new Map(
		rules.map((rule) => {
			const scope = ruleScopes.get(rule.objectID) ?? null;
			return [rule.objectID, scope !== null && (scopeCounts.get(scope) ?? 0) > 1];
		})
	);
}

export function normalizeRule(rule: Partial<Rule>): Rule {
	return {
		...rule,
		objectID: rule.objectID ?? '',
		conditions: Array.isArray(rule.conditions) ? rule.conditions : [],
		consequence: rule.consequence ?? {}
	} as Rule;
}

export function createEmptyRule(timestamp = Date.now()): Rule {
	return {
		objectID: `rule-${timestamp}`,
		conditions: [{ pattern: '' }],
		consequence: {},
		description: '',
		enabled: false
	};
}

export function ruleStateFromEnabled(enabled: unknown): RuleEditorState {
	return enabled === false ? 'draft' : 'published';
}

export function enabledFromRuleState(state: unknown): boolean {
	return state !== 'draft';
}

function parseDatetimeLocalParts(value: string): {
	year: number;
	monthIndex: number;
	day: number;
	hours: number;
	minutes: number;
} | null {
	const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/.exec(value);
	if (!match) return null;

	const [, yearText, monthText, dayText, hourText, minuteText] = match;
	const year = Number.parseInt(yearText, 10);
	const monthIndex = Number.parseInt(monthText, 10) - 1;
	const day = Number.parseInt(dayText, 10);
	const hours = Number.parseInt(hourText, 10);
	const minutes = Number.parseInt(minuteText, 10);

	if (
		monthIndex < 0 ||
		monthIndex > 11 ||
		day < 1 ||
		day > 31 ||
		hours < 0 ||
		hours > 23 ||
		minutes < 0 ||
		minutes > 59
	) {
		return null;
	}

	return { year, monthIndex, day, hours, minutes };
}

export function datetimeLocalToUtcSeconds(value: string): number | null {
	const trimmed = value.trim();
	if (!trimmed) return null;
	const parts = parseDatetimeLocalParts(trimmed);
	if (!parts) return null;

	const localInstant = new Date(
		parts.year,
		parts.monthIndex,
		parts.day,
		parts.hours,
		parts.minutes,
		0,
		0
	);
	if (
		localInstant.getFullYear() !== parts.year ||
		localInstant.getMonth() !== parts.monthIndex ||
		localInstant.getDate() !== parts.day ||
		localInstant.getHours() !== parts.hours ||
		localInstant.getMinutes() !== parts.minutes
	) {
		return null;
	}

	return localInstant.getTime() / 1000;
}

function zeroPad(value: number): string {
	return String(value).padStart(2, '0');
}

export function utcSecondsToDatetimeLocal(value: unknown): string {
	if (typeof value !== 'number' || !Number.isFinite(value)) return '';
	const localInstant = new Date(value * 1000);
	return [
		localInstant.getFullYear(),
		zeroPad(localInstant.getMonth() + 1),
		zeroPad(localInstant.getDate())
	]
		.join('-')
		.concat('T')
		.concat([zeroPad(localInstant.getHours()), zeroPad(localInstant.getMinutes())].join(':'));
}

function normalizedPositiveInteger(value: number | string | null | undefined): number {
	const parsed = typeof value === 'number' ? value : Number.parseInt(String(value ?? ''), 10);
	return Number.isInteger(parsed) && parsed > 0 ? parsed : 0;
}

function structuredValidity(input: RuleBuilderInput): RuleValidityRange[] | undefined {
	const from = datetimeLocalToUtcSeconds(input.validFrom ?? '');
	const until = datetimeLocalToUtcSeconds(input.validUntil ?? '');
	return from !== null && until !== null ? [{ from, until }] : undefined;
}

export function buildRuleConsequenceFromStructuredInput(
	baseConsequence: Rule['consequence'],
	input: RuleConsequenceBuilderInput
): Rule['consequence'] {
	const promoteObjectID = input.promoteObjectID?.trim() ?? '';
	const hideObjectID = input.hideObjectID?.trim() ?? '';
	const promotePosition = normalizedPositiveInteger(input.promotePosition);
	const consequence = { ...(baseConsequence ?? {}) };

	if (promoteObjectID) {
		consequence.promote = [{ objectID: promoteObjectID, position: promotePosition }];
	} else {
		delete consequence.promote;
	}

	if (hideObjectID) {
		consequence.hide = [{ objectID: hideObjectID }];
	} else {
		delete consequence.hide;
	}

	return consequence;
}

export function buildRuleFromStructuredInput(baseRule: Rule, input: RuleBuilderInput): Rule {
	const normalizedBase = normalizeRule(baseRule);
	const firstCondition = normalizedBase.conditions[0] ?? {};
	const filters = input.filterScope?.trim() ?? '';
	const pattern = input.queryPattern.trim();
	const validity = structuredValidity(input);
	const merchandisingCondition: RuleCondition = { ...firstCondition };
	const consequence = buildRuleConsequenceFromStructuredInput(normalizedBase.consequence, input);

	if (pattern) {
		merchandisingCondition.pattern = pattern;
		merchandisingCondition.anchoring = input.anchoring;
	} else {
		delete merchandisingCondition.pattern;
		delete merchandisingCondition.anchoring;
	}
	if (filters) {
		merchandisingCondition.filters = filters;
	} else {
		delete merchandisingCondition.filters;
	}

	const rule: Rule = {
		...normalizedBase,
		objectID: input.objectID.trim(),
		description: input.description ?? '',
		enabled: enabledFromRuleState(input.state),
		conditions: [merchandisingCondition, ...normalizedBase.conditions.slice(1)],
		consequence
	};

	if (validity) {
		rule.validity = validity;
	} else {
		delete rule.validity;
	}

	return rule;
}

export function ruleForPublish(rule: Rule): Rule {
	return {
		...rule,
		enabled: true
	};
}

export function createMerchandisingRule({
	query,
	description,
	pins,
	hides,
	timestamp = Date.now()
}: CreateMerchandisingRuleInput): Rule {
	return {
		objectID: `merch-${slugify(query)}-${timestamp}`,
		conditions: [{ pattern: query, anchoring: 'is' }],
		consequence: {
			...(pins.length > 0 ? { promote: pins } : {}),
			...(hides.length > 0 ? { hide: hides } : {})
		},
		description: description || `Merchandising: "${query}"`,
		enabled: true
	};
}

export function buildRuleDescription(rule: Rule): string {
	const parts: string[] = [];
	const condition = rule.conditions[0];

	if (condition) {
		if (condition.pattern && condition.anchoring) {
			parts.push(`When query ${condition.anchoring} "${condition.pattern}"`);
		}
		if (condition.context) {
			parts.push(`When context "${condition.context}"`);
		}
		if (condition.filters) {
			parts.push(`When filters "${condition.filters}"`);
		}
	}

	const promotes = rule.consequence.promote?.length || 0;
	const hides = rule.consequence.hide?.length || 0;

	if (promotes) parts.push(`pin ${promotes} result${promotes > 1 ? 's' : ''}`);
	if (hides) parts.push(`hide ${hides} result${hides > 1 ? 's' : ''}`);
	if (rule.consequence.params?.query !== undefined) parts.push('modify query');

	return parts.join(', ') || 'No conditions or consequences';
}

function cleanParams(params?: Record<string, unknown>): Record<string, unknown> | undefined {
	if (!params) return undefined;

	const clean: Record<string, unknown> = {};
	for (const [key, value] of Object.entries(params)) {
		if (value === undefined || value === null || value === '') continue;
		if (Array.isArray(value) && value.length === 0) continue;
		clean[key] = value;
	}

	return Object.keys(clean).length > 0 ? clean : undefined;
}

export function normalizeRuleForSerialization(rule: Rule): Rule {
	const normalizedRule = normalizeRule(rule);
	const conditions = normalizedRule.conditions
		.map((condition) => {
			const pattern = condition.pattern?.trim();
			const context = condition.context?.trim();
			const filters = condition.filters?.trim();
			const hasAnchoring = condition.anchoring !== undefined;
			const hasPattern = Boolean(pattern);
			const hasContext = Boolean(context);
			const hasFilters = Boolean(filters);
			const hasAlternatives = condition.alternatives === true;

			if (!hasPattern && !hasAnchoring && !hasContext && !hasFilters && !hasAlternatives) {
				return null;
			}

			return {
				...(hasPattern ? { pattern } : {}),
				...(hasAnchoring ? { anchoring: condition.anchoring } : {}),
				...(hasAlternatives ? { alternatives: true } : {}),
				...(hasContext ? { context } : {}),
				...(hasFilters ? { filters } : {})
			} as RuleCondition;
		})
		.filter((condition): condition is RuleCondition => condition !== null);

	const consequence = { ...normalizedRule.consequence };
	if (consequence.params) {
		consequence.params = cleanParams(
			consequence.params as Record<string, unknown>
		) as typeof consequence.params;
	}
	if (!consequence.promote?.length) delete consequence.promote;
	if (!consequence.hide?.length) delete consequence.hide;
	if (!consequence.userData) delete consequence.userData;

	const result: Rule = {
		...normalizedRule,
		conditions,
		consequence
	};

	if (result.validity && result.validity.length === 0) {
		delete result.validity;
	}

	return result;
}

export function validateRule(rule: Rule): string[] {
	const errors: string[] = [];

	rule.conditions.forEach((condition, index) => {
		const hasPattern = Boolean(condition.pattern?.trim());
		const hasAnchoring = condition.anchoring !== undefined;

		if (hasPattern && !hasAnchoring) {
			errors.push(`Condition ${index + 1}: anchoring is required when pattern is provided.`);
		}
		if (!hasPattern && hasAnchoring) {
			errors.push(`Condition ${index + 1}: pattern is required when anchoring is selected.`);
		}
	});

	const userData: unknown = rule.consequence.userData;
	if (userData !== undefined && userData !== '') {
		if (typeof userData === 'string') {
			try {
				JSON.parse(userData);
			} catch {
				errors.push('Invalid JSON in User Data field.');
			}
		}
	}

	if (rule.consequence.params?.renderingContent !== undefined) {
		if (typeof rule.consequence.params.renderingContent === 'string') {
			try {
				JSON.parse(rule.consequence.params.renderingContent);
			} catch {
				errors.push('Invalid JSON in Rendering Content field.');
			}
		}
	}

	if (rule.consequence.promote?.length) {
		const ids = rule.consequence.promote.map((promote) => {
			const objectID = promote.objectID;
			if (typeof objectID === 'string') {
				return objectID;
			}
			const objectIDs = promote.objectIDs;
			if (Array.isArray(objectIDs)) {
				return objectIDs.join(',');
			}
			return '';
		});
		const seen = new Set<string>();
		for (const id of ids) {
			if (id && seen.has(id)) {
				errors.push('Duplicate objectID in promoted items.');
				break;
			}
			if (id) seen.add(id);
		}
		for (const promote of rule.consequence.promote) {
			const position = promote.position;
			if (typeof position !== 'number' || !Number.isInteger(position) || position < 1) {
				errors.push('Promote position must be a positive whole number.');
				break;
			}
		}
	}

	return errors;
}

export function prepareRuleEditorSave(rule: Rule): PrepareRuleEditorSaveResult {
	const candidateRule = normalizeRuleForSerialization(rule);
	const validationErrors = validateRule(candidateRule);

	if (validationErrors.length > 0) {
		return { error: validationErrors[0] };
	}

	const serializedRule: Rule = {
		...candidateRule,
		consequence: {
			...candidateRule.consequence,
			params: candidateRule.consequence.params ? { ...candidateRule.consequence.params } : undefined
		}
	};

	if (
		typeof serializedRule.consequence.userData === 'string' &&
		serializedRule.consequence.userData
	) {
		serializedRule.consequence.userData = JSON.parse(serializedRule.consequence.userData);
	} else if (!serializedRule.consequence.userData) {
		delete serializedRule.consequence.userData;
	}

	if (
		serializedRule.consequence.params?.renderingContent &&
		typeof serializedRule.consequence.params.renderingContent === 'string'
	) {
		serializedRule.consequence.params.renderingContent = JSON.parse(
			serializedRule.consequence.params.renderingContent
		);
	}

	const json = JSON.stringify(serializedRule, null, 2);
	const parsed = parseRuleEditorJson(json);

	return {
		...parsed,
		json
	};
}

export function parseRuleEditorJson(json: string): ParseRuleEditorJsonResult {
	try {
		const parsed = JSON.parse(json) as Partial<Rule>;

		if (!parsed || typeof parsed !== 'object') {
			return { error: 'rule must be a JSON object' };
		}

		if (parsed.objectID === undefined || parsed.objectID === null) {
			return { error: 'objectID is required' };
		}

		if (typeof parsed.objectID !== 'string' || parsed.objectID.trim().length === 0) {
			return { error: 'objectID must be a non-empty string' };
		}

		if (parsed.consequence === undefined || parsed.consequence === null) {
			return { error: 'consequence is required' };
		}

		if (typeof parsed.consequence !== 'object' || Array.isArray(parsed.consequence)) {
			return { error: 'consequence must be an object' };
		}

		return { rule: normalizeRule(parsed) };
	} catch (error) {
		return {
			error: error instanceof Error ? error.message : 'Invalid JSON'
		};
	}
}
