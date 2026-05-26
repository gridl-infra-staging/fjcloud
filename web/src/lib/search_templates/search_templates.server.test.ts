import { describe, expect, it } from 'vitest';
import { indexTemplateServerSnapshots } from './search_templates.server';

describe('search template server snapshot contract', () => {
	it('contains one local payload owner with expected document counts', () => {
		expect(indexTemplateServerSnapshots.empty.documents).toHaveLength(0);
		expect(indexTemplateServerSnapshots.movies.documents).toHaveLength(1000);
		expect(indexTemplateServerSnapshots.products.documents).toHaveLength(1000);
	});

	it('locks movies settings, synonyms, and rules contract', () => {
		expect(indexTemplateServerSnapshots.movies.settings).toEqual({
			searchableAttributes: ['title', 'overview', 'director'],
			attributesForFaceting: ['genre', 'director', 'year'],
			attributesToHighlight: ['title', 'overview', 'director']
		});
		expect(indexTemplateServerSnapshots.movies.synonyms).toHaveLength(8);
		expect(indexTemplateServerSnapshots.movies.rules).toHaveLength(2);
	});

	it('locks products settings, synonyms, and rules contract', () => {
		expect(indexTemplateServerSnapshots.products.settings).toEqual({
			searchableAttributes: ['name', 'description', 'brand', 'category'],
			attributesForFaceting: ['category', 'brand', 'inStock'],
			attributesToHighlight: ['name', 'description']
		});
		expect(indexTemplateServerSnapshots.products.synonyms).toHaveLength(8);
		expect(indexTemplateServerSnapshots.products.rules).toHaveLength(2);
	});
});
