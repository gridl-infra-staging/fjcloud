import type {
	EditorDialogFieldSchema,
	EditorDialogValues
} from '$lib/components/EditorDialog.types';

export const demoSchema: EditorDialogFieldSchema[] = [
	{ type: 'text', name: 'title', label: 'Title', required: true, maxLength: 120 },
	{ type: 'textarea', name: 'description', label: 'Description', rows: 3 },
	{
		type: 'select',
		name: 'model',
		label: 'Model',
		required: true,
		options: [
			{ value: 'trending-items', label: 'Trending Items' },
			{ value: 'trending-facets', label: 'Trending Facets' }
		]
	},
	{
		type: 'multiselect',
		name: 'facets',
		label: 'Facet Filters',
		options: [
			{ value: 'brand', label: 'Brand' },
			{ value: 'category', label: 'Category' },
			{ value: 'color', label: 'Color' }
		]
	},
	{
		type: 'number',
		name: 'limit',
		label: 'Limit',
		required: true,
		min: 1,
		max: 100,
		integer: true
	},
	{ type: 'toggle', name: 'enabled', label: 'Enabled' },
	{
		type: 'radio',
		name: 'rankingMode',
		label: 'Ranking mode',
		options: [
			{ value: 'balanced', label: 'Balanced' },
			{ value: 'aggressive', label: 'Aggressive' }
		]
	},
	{ type: 'datetime-local', name: 'activationAt', label: 'Activation time' },
	{
		type: 'array',
		name: 'keywords',
		label: 'Keywords',
		addLabel: 'Add keyword',
		item: { type: 'text', name: 'keyword', label: 'Keyword', required: true }
	},
	{
		type: 'array',
		name: 'boosts',
		label: 'Boost rules',
		addLabel: 'Add boost rule',
		item: {
			type: 'group',
			fields: [
				{ type: 'text', name: 'attribute', label: 'Attribute', required: true },
				{ type: 'number', name: 'weight', label: 'Weight', required: true }
			]
		}
	}
];

export const createSeedValue: EditorDialogValues = {
	title: '',
	description: '',
	model: 'trending-items',
	facets: ['brand'],
	limit: 10,
	enabled: true,
	rankingMode: 'balanced',
	activationAt: '',
	keywords: ['featured'],
	boosts: [{ attribute: 'brand', weight: 2 }]
};

export const editSeedValue: EditorDialogValues = {
	title: 'Existing rule',
	description: 'Previously saved',
	model: 'trending-facets',
	facets: ['category'],
	limit: 25,
	enabled: false,
	rankingMode: 'aggressive',
	activationAt: '2026-05-20T09:30',
	keywords: ['legacy', 'carryover'],
	boosts: [{ attribute: 'category', weight: 3 }]
};
