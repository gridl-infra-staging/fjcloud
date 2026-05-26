import type { Rule, Synonym } from '$lib/api/types';
import type { IndexTemplateId } from './template_metadata';
import moviesDocuments from './movies.json';
import productsDocuments from './products.json';

type TemplateServerSnapshot = {
	settings: Record<string, unknown>;
	synonyms: Synonym[];
	rules: Rule[];
	documents: Record<string, unknown>[];
};

const MOVIES_SYNONYMS: Synonym[] = [
	{ type: 'synonym', objectID: 'syn-film-movie', synonyms: ['film', 'movie', 'picture', 'flick'] },
	{
		type: 'synonym',
		objectID: 'syn-scary-horror',
		synonyms: ['scary', 'horror', 'frightening', 'terrifying']
	},
	{
		type: 'synonym',
		objectID: 'syn-funny-comedy',
		synonyms: ['funny', 'comedy', 'humorous', 'hilarious']
	},
	{
		type: 'onewaysynonym',
		objectID: 'syn-scifi',
		input: 'sci-fi',
		synonyms: ['science fiction', 'futuristic', 'space']
	},
	{
		type: 'onewaysynonym',
		objectID: 'syn-animated',
		input: 'cartoon',
		synonyms: ['animated', 'animation']
	},
	{
		type: 'synonym',
		objectID: 'syn-war-battle',
		synonyms: ['war', 'battle', 'combat', 'military']
	},
	{ type: 'synonym', objectID: 'syn-love-romance', synonyms: ['love', 'romance', 'romantic'] },
	{
		type: 'synonym',
		objectID: 'syn-detective-mystery',
		synonyms: ['detective', 'mystery', 'whodunit', 'investigation']
	}
];

const MOVIES_RULES: Rule[] = [
	{
		objectID: 'rule-best-movies',
		conditions: [{ pattern: 'best', anchoring: 'contains' }],
		consequence: {
			params: { query: '' }
		},
		description: 'When searching best, show highest-rated movies'
	},
	{
		objectID: 'rule-nolan',
		conditions: [{ pattern: 'nolan', anchoring: 'contains' }],
		consequence: {
			promote: [
				{ objectID: 'movie_3', position: 0 },
				{ objectID: 'movie_9', position: 1 },
				{ objectID: 'movie_13', position: 2 }
			]
		},
		description: 'Promote top Nolan films when searching for nolan'
	}
];

const PRODUCTS_SYNONYMS: Synonym[] = [
	{
		type: 'synonym',
		objectID: 'syn-laptop-notebook',
		synonyms: ['laptop', 'notebook', 'computer']
	},
	{
		type: 'synonym',
		objectID: 'syn-headphones-earbuds',
		synonyms: ['headphones', 'earbuds', 'earphones', 'headset']
	},
	{ type: 'synonym', objectID: 'syn-shirt-tee', synonyms: ['shirt', 'tee', 't-shirt', 'top'] },
	{
		type: 'synonym',
		objectID: 'syn-sneakers-shoes',
		synonyms: ['sneakers', 'shoes', 'trainers', 'kicks']
	},
	{
		type: 'onewaysynonym',
		objectID: 'syn-cheap',
		input: 'cheap',
		synonyms: ['affordable', 'budget', 'value']
	},
	{
		type: 'onewaysynonym',
		objectID: 'syn-premium',
		input: 'premium',
		synonyms: ['luxury', 'high-end', 'pro']
	},
	{
		type: 'synonym',
		objectID: 'syn-bottle-flask',
		synonyms: ['bottle', 'flask', 'tumbler', 'canteen']
	},
	{
		type: 'synonym',
		objectID: 'syn-bag-backpack',
		synonyms: ['bag', 'backpack', 'pack', 'rucksack']
	}
];

const PRODUCTS_RULES: Rule[] = [
	{
		objectID: 'rule-featured-electronics',
		conditions: [{ pattern: 'electronics', anchoring: 'contains' }],
		consequence: {
			promote: [
				{ objectID: 'prod_1', position: 0 },
				{ objectID: 'prod_7', position: 1 }
			]
		},
		description: 'Promote headphones and keyboard for electronics searches'
	},
	{
		objectID: 'rule-gift-ideas',
		conditions: [{ pattern: 'gift', anchoring: 'contains' }],
		consequence: {
			promote: [
				{ objectID: 'prod_9', position: 0 },
				{ objectID: 'prod_5', position: 1 }
			]
		},
		description: 'Promote giftable items when searching for gift'
	}
];

const MOVIES_SETTINGS = {
	searchableAttributes: ['title', 'overview', 'director'],
	attributesForFaceting: ['genre', 'director', 'year'],
	attributesToHighlight: ['title', 'overview', 'director']
} satisfies Record<string, unknown>;

const PRODUCTS_SETTINGS = {
	searchableAttributes: ['name', 'description', 'brand', 'category'],
	attributesForFaceting: ['category', 'brand', 'inStock'],
	attributesToHighlight: ['name', 'description']
} satisfies Record<string, unknown>;

export const indexTemplateServerSnapshots: Record<IndexTemplateId, TemplateServerSnapshot> = {
	empty: {
		settings: {},
		synonyms: [],
		rules: [],
		documents: []
	},
	movies: {
		settings: MOVIES_SETTINGS,
		synonyms: MOVIES_SYNONYMS,
		rules: MOVIES_RULES,
		documents: moviesDocuments as Record<string, unknown>[]
	},
	products: {
		settings: PRODUCTS_SETTINGS,
		synonyms: PRODUCTS_SYNONYMS,
		rules: PRODUCTS_RULES,
		documents: productsDocuments as Record<string, unknown>[]
	}
};

export function getIndexTemplateServerSnapshot(
	templateId: IndexTemplateId
): TemplateServerSnapshot {
	return indexTemplateServerSnapshots[templateId];
}
