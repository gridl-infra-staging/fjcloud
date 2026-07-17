export type SettingsDraft = Record<string, unknown>;
export type SettingsDraftMutator = (draft: SettingsDraft) => void;

export const QUICK_CONTROL_ERROR =
	'Settings JSON must be a valid JSON object to use quick controls.';

const DEFAULT_EMBEDDERS: SettingsDraft = {
	default: {
		source: 'userProvided',
		dimensions: 384
	}
};

const DEFAULT_HYBRID: SettingsDraft = {
	semanticRatio: 0.5
};

// Single source of truth for the engine-defined settings keys whose edits force a
// full reindex. These are the reindex-trigger keys the repo can already load and save.
// TODO: revisit if the engine surface later marks additional keys (e.g. typoTolerance,
// separatorTokens) reindex-risky; leave uncertain keys out until proven.
export const REINDEX_RISK_SETTINGS_KEYS = [
	'searchableAttributes',
	'filterableAttributes',
	'sortableAttributes',
	'distinctAttribute'
] as const;

export function isRecord(value: unknown): value is SettingsDraft {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

// Pure diff: returns the reindex-risk keys whose value differs between the
// server-hydrated settings object and the current parsed draft. Runs against the
// parsed draft (Record<string, unknown>), so raw Advanced JSON edits and structured
// subtab edits are both covered.
export function getChangedReindexRiskFields(
	serverSettings: SettingsDraft | null,
	draft: SettingsDraft | null
): string[] {
	const server = serverSettings ?? {};
	const current = draft ?? {};
	return REINDEX_RISK_SETTINGS_KEYS.filter(
		(key) => JSON.stringify(server[key]) !== JSON.stringify(current[key])
	);
}

export function parseSettingsDraftText(settingsText: string): SettingsDraft | null {
	try {
		const parsed: unknown = JSON.parse(settingsText);
		return isRecord(parsed) ? parsed : null;
	} catch {
		return null;
	}
}

export function stringifySettingsDraft(settings: SettingsDraft | null): string {
	return JSON.stringify(settings ?? {}, null, 2);
}

export function updateSettingsDraftText(
	settingsText: string,
	mutator: SettingsDraftMutator
): { settingsText: string; error: string } {
	const parsed = parseSettingsDraftText(settingsText);
	if (!parsed) {
		return { settingsText, error: QUICK_CONTROL_ERROR };
	}

	mutator(parsed);
	return { settingsText: stringifySettingsDraft(parsed), error: '' };
}

export function resetSettingsDraftText(settings: SettingsDraft | null): string {
	return stringifySettingsDraft(settings);
}

export function parseCommaSeparatedList(value: string): string[] {
	return value
		.split(',')
		.map((item) => item.trim())
		.filter((item) => item.length > 0);
}

export function formatStringList(value: unknown): string {
	return Array.isArray(value)
		? value.filter((item): item is string => typeof item === 'string').join(', ')
		: '';
}

export function parseOptionalInteger(value: string): number | null {
	if (value.trim().length === 0) return null;
	const parsed = Number.parseInt(value, 10);
	return Number.isNaN(parsed) ? null : parsed;
}

export function getOptionalString(value: unknown): string {
	return typeof value === 'string' ? value : '';
}

export function getOptionalIntegerString(value: unknown): string {
	return typeof value === 'number' && Number.isInteger(value) ? String(value) : '';
}

export function getEmbedderEntries(value: unknown): [string, SettingsDraft][] {
	if (!isRecord(value)) return [];
	return Object.entries(value).filter((entry): entry is [string, SettingsDraft] =>
		isRecord(entry[1])
	);
}

export function getEmbedderDraftEntry(draft: SettingsDraft, name: string): SettingsDraft | null {
	const embedders = draft.embedders;
	if (!isRecord(embedders)) return null;
	const entry = embedders[name];
	return isRecord(entry) ? entry : null;
}

export function createDefaultEmbedders(): SettingsDraft {
	return structuredClone(DEFAULT_EMBEDDERS);
}

export function createDefaultHybridSettings(draft: SettingsDraft): SettingsDraft {
	const firstEmbedderName = getEmbedderEntries(draft.embedders)[0]?.[0];
	return {
		...DEFAULT_HYBRID,
		embedder: firstEmbedderName ?? 'default'
	};
}

export function updateHybridDraft(
	draft: SettingsDraft,
	updateHybrid: (hybrid: SettingsDraft) => void
): void {
	const hybrid = draft.hybrid;
	if (!isRecord(hybrid)) return;
	updateHybrid(hybrid);
}
