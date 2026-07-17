/** Per-index browser persistence for the Search as you type preview choice. */
const STORAGE_KEY = 'search_preview_instant_search';

function storage(): Storage | null {
	try {
		return globalThis.localStorage ?? null;
	} catch {
		return null;
	}
}

function readStoredRecord(target: Storage): Record<string, unknown> {
	const raw = target.getItem(STORAGE_KEY);
	if (!raw) return {};
	const parsed: unknown = JSON.parse(raw);
	return typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)
		? (parsed as Record<string, unknown>)
		: {};
}

export function loadInstantSearchEnabled(indexName: string): boolean {
	const target = storage();
	if (!target) return false;
	try {
		return readStoredRecord(target)[indexName] === true;
	} catch {
		return false;
	}
}

export function saveInstantSearchEnabled(indexName: string, enabled: boolean): void {
	const target = storage();
	if (!target) return;
	try {
		let stored: Record<string, unknown> = {};
		try {
			stored = readStoredRecord(target);
		} catch {
			// Replace malformed app-owned state so the customer's next choice persists.
		}
		target.setItem(STORAGE_KEY, JSON.stringify({ ...stored, [indexName]: enabled }));
	} catch {
		// Search remains usable when browser storage is unavailable.
	}
}
