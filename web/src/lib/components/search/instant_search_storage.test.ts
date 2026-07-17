import { afterEach, describe, expect, it, vi } from 'vitest';

import { loadInstantSearchEnabled, saveInstantSearchEnabled } from './instant_search_storage';

afterEach(() => {
	vi.unstubAllGlobals();
});

describe('instant search storage', () => {
	it('stores the checkbox independently for each index', () => {
		const values = new Map<string, string>();
		vi.stubGlobal('localStorage', {
			getItem: (key: string) => values.get(key) ?? null,
			setItem: (key: string, value: string) => values.set(key, value)
		});

		saveInstantSearchEnabled('products', true);
		expect(loadInstantSearchEnabled('products')).toBe(true);
		expect(loadInstantSearchEnabled('articles')).toBe(false);

		saveInstantSearchEnabled('products', false);
		expect(loadInstantSearchEnabled('products')).toBe(false);
	});

	it('falls back to off when storage contains malformed JSON', () => {
		const setItem = vi.fn();
		vi.stubGlobal('localStorage', {
			getItem: () => '{broken',
			setItem
		});

		expect(loadInstantSearchEnabled('products')).toBe(false);
		saveInstantSearchEnabled('products', true);
		expect(setItem).toHaveBeenCalledWith(
			'search_preview_instant_search',
			JSON.stringify({ products: true })
		);
	});
});
