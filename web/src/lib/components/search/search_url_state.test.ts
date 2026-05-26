import { describe, expect, it } from 'vitest';

import {
	buildSearchUrlWithState,
	parseSearchUrlState,
	serializeSearchUrlState
} from './search_url_state';

describe('search_url_state', () => {
	it('round-trips q, p, f, and hr via serialize + parse', () => {
		const serialized = serializeSearchUrlState({
			query: 'boots',
			page: 3,
			filters: ['brand:Acme', 'in_stock:true'],
			hitsPerPage: 40
		});

		expect(serialized).toBe('q=boots&p=3&f=brand%3AAcme%2Cin_stock%3Atrue&hr=40');
		expect(parseSearchUrlState(new URLSearchParams(serialized))).toEqual({
			query: 'boots',
			page: 3,
			filters: ['brand:Acme', 'in_stock:true'],
			hitsPerPage: 40
		});
	});

	it('additively merges owned keys into an existing URL without dropping foreign keys', () => {
		const merged = buildSearchUrlWithState(
			'https://example.test/console/indexes/cust?welcome=1&tab=search-preview',
			{
				query: 'svelte',
				page: 2,
				filters: ['status:active'],
				hitsPerPage: 25
			}
		);

		expect(merged).toBe(
			'https://example.test/console/indexes/cust?welcome=1&tab=search-preview&q=svelte&p=2&f=status%3Aactive&hr=25'
		);
	});

	it('preserves existing foreign keys when owned keys are updated', () => {
		const merged = buildSearchUrlWithState(
			'https://example.test/console/indexes/cust?welcome=true&tab=overview&q=old&p=9',
			{
				query: 'new',
				page: 1,
				filters: [],
				hitsPerPage: 10
			}
		);

		expect(merged).toBe(
			'https://example.test/console/indexes/cust?welcome=true&tab=overview&q=new&p=1&hr=10'
		);
	});
});
