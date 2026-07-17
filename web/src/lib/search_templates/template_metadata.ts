export type IndexTemplateId = 'empty' | 'movies' | 'products';

export type IndexTemplateMetadata = {
	id: IndexTemplateId;
	label: string;
	description: string;
	defaultName: string;
};

export const EMPTY_TEMPLATE_ID: IndexTemplateId = 'empty';

export const indexTemplateMetadata: IndexTemplateMetadata[] = [
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
];
