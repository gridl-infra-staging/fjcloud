import { describe, expect, it } from 'vitest';
import { indexTemplateMetadata } from './index';

describe('search template metadata contract', () => {
	it('exposes exact client-safe metadata for all three templates', () => {
		expect(indexTemplateMetadata).toEqual([
			{
				id: 'empty',
				label: 'Empty index',
				description: 'Start from scratch — add your own documents later',
				defaultName: ''
			},
			{
				id: 'movies',
				label: 'Movies — 1,000 docs',
				description:
					'Search by title/director, filter by genre, includes synonyms & merchandising rules',
				defaultName: 'movies'
			},
			{
				id: 'products',
				label: 'Products — 1,000 docs',
				description: 'E-commerce demo with facets, synonyms & merchandising rules',
				defaultName: 'products'
			}
		]);
	});

	it('keeps metadata client-safe by exposing only display and default-name fields', () => {
		for (const template of indexTemplateMetadata) {
			expect(Object.keys(template).sort()).toEqual(['defaultName', 'description', 'id', 'label']);
		}
	});
});
