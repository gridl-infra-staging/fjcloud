import { describe, expect, it } from 'vitest';

import {
	buildQueryString,
	dictionaryPath,
	experimentPath,
	indexPath,
	pathSegment
} from './client_paths';

describe('API client path helpers', () => {
	it('encodes path segments and composes index subresources exactly', () => {
		expect(pathSegment('products/us east')).toBe('products%2Fus%20east');
		expect(indexPath('products/us east', '/settings')).toBe(
			'/indexes/products%2Fus%20east/settings'
		);
		expect(experimentPath('products/us east', 'experiment/7', '/results')).toBe(
			'/indexes/products%2Fus%20east/experiments/experiment%2F7/results'
		);
		expect(dictionaryPath('products/us east', 'stop/words', '/search')).toBe(
			'/indexes/products%2Fus%20east/dictionaries/stop%2Fwords/search'
		);
	});

	it('omits undefined query values while preserving zero and encoding values', () => {
		expect(
			buildQueryString([
				['month', '2026/07'],
				['page', 0],
				['cursor', undefined]
			])
		).toBe('?month=2026%2F07&page=0');
		expect(buildQueryString([['cursor', undefined]])).toBe('');
	});
});
