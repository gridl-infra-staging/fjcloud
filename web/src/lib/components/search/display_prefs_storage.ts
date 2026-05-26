export const DISPLAY_PREFS_STORAGE_KEY = 'search_preview_display_prefs';

export type SearchDisplayPrefs = {
	hitsPerPage: number;
	highlightedAttributes: string[];
};

const DEFAULT_SEARCH_DISPLAY_PREFS: SearchDisplayPrefs = {
	hitsPerPage: 20,
	highlightedAttributes: []
};

function getBrowserStorage(): Storage | null {
	const storage = globalThis.localStorage;
	if (!storage) {
		return null;
	}

	return storage;
}

export function loadSearchDisplayPrefs(): SearchDisplayPrefs {
	const storage = getBrowserStorage();
	if (!storage) {
		return DEFAULT_SEARCH_DISPLAY_PREFS;
	}

	const raw = storage.getItem(DISPLAY_PREFS_STORAGE_KEY);
	if (!raw) {
		return DEFAULT_SEARCH_DISPLAY_PREFS;
	}

	try {
		const parsed = JSON.parse(raw) as Partial<SearchDisplayPrefs>;
		return {
			hitsPerPage:
				typeof parsed.hitsPerPage === 'number'
					? parsed.hitsPerPage
					: DEFAULT_SEARCH_DISPLAY_PREFS.hitsPerPage,
			highlightedAttributes: Array.isArray(parsed.highlightedAttributes)
				? parsed.highlightedAttributes.filter((value): value is string => typeof value === 'string')
				: DEFAULT_SEARCH_DISPLAY_PREFS.highlightedAttributes
		};
	} catch {
		return DEFAULT_SEARCH_DISPLAY_PREFS;
	}
}

export function saveSearchDisplayPrefs(preferences: SearchDisplayPrefs): void {
	const storage = getBrowserStorage();
	if (!storage) {
		return;
	}

	storage.setItem(DISPLAY_PREFS_STORAGE_KEY, JSON.stringify(preferences));
}
