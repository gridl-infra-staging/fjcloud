import { afterEach, describe, expect, it, vi } from 'vitest';

import {
	DISPLAY_PREFS_STORAGE_KEY,
	loadSearchDisplayPrefs,
	saveSearchDisplayPrefs
} from './display_prefs_storage';

afterEach(() => {
	vi.unstubAllGlobals();
	vi.restoreAllMocks();
});

describe('display_prefs_storage', () => {
	it('returns defaults when localStorage is unavailable (SSR/non-browser)', () => {
		// Simulates SSR/non-browser runtime where localStorage is not defined.
		vi.unstubAllGlobals();

		expect(loadSearchDisplayPrefs()).toEqual({ hitsPerPage: 20, highlightedAttributes: [] });
	});

	it('loads defaults when localStorage has no saved value', () => {
		const getItem = vi.fn().mockReturnValue(null);
		vi.stubGlobal('localStorage', { getItem, setItem: vi.fn() });

		expect(loadSearchDisplayPrefs()).toEqual({ hitsPerPage: 20, highlightedAttributes: [] });
		expect(getItem).toHaveBeenCalledWith(DISPLAY_PREFS_STORAGE_KEY);
	});

	it('loads saved prefs from localStorage', () => {
		vi.stubGlobal('localStorage', {
			getItem: vi
				.fn()
				.mockReturnValue('{"hitsPerPage":50,"highlightedAttributes":["title","body"]}'),
			setItem: vi.fn()
		});

		expect(loadSearchDisplayPrefs()).toEqual({
			hitsPerPage: 50,
			highlightedAttributes: ['title', 'body']
		});
	});

	it('falls back to defaults when localStorage data is malformed', () => {
		vi.stubGlobal('localStorage', {
			getItem: vi.fn().mockReturnValue('not-json'),
			setItem: vi.fn()
		});

		expect(loadSearchDisplayPrefs()).toEqual({ hitsPerPage: 20, highlightedAttributes: [] });
	});

	it('saves prefs to the canonical storage key', () => {
		const setItem = vi.fn();
		vi.stubGlobal('localStorage', { getItem: vi.fn(), setItem });

		saveSearchDisplayPrefs({ hitsPerPage: 40, highlightedAttributes: ['body'] });

		expect(setItem).toHaveBeenCalledWith(
			DISPLAY_PREFS_STORAGE_KEY,
			'{"hitsPerPage":40,"highlightedAttributes":["body"]}'
		);
	});
});
