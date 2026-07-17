export type RecommendationModelId =
	| 'related-products'
	| 'bought-together'
	| 'trending-items'
	| 'trending-facets'
	| 'looking-similar';

export type RecommendationModelMetadata = {
	id: RecommendationModelId;
	label: string;
	requiresObjectID: boolean;
	requiresFacetName: boolean;
	description: string;
};

export const DEFAULT_RECOMMENDATION_MODEL: RecommendationModelId = 'related-products';

export const RECOMMENDATION_MODELS: RecommendationModelMetadata[] = [
	{
		id: 'related-products',
		label: 'Related Products',
		requiresObjectID: true,
		requiresFacetName: false,
		description:
			'Use one record as the starting point and return products that are usually relevant alongside it.'
	},
	{
		id: 'bought-together',
		label: 'Bought Together',
		requiresObjectID: true,
		requiresFacetName: false,
		description:
			'Start from one record and return items customers commonly engage with in the same session or basket.'
	},
	{
		id: 'trending-items',
		label: 'Trending Items',
		requiresObjectID: false,
		requiresFacetName: false,
		description: 'Show the most popular items in this index without needing a source objectID.'
	},
	{
		id: 'trending-facets',
		label: 'Trending Facets',
		requiresObjectID: false,
		requiresFacetName: true,
		description:
			'Show the facet values that are trending for the facet you choose, such as category or brand.'
	},
	{
		id: 'looking-similar',
		label: 'Looking Similar',
		requiresObjectID: true,
		requiresFacetName: false,
		description:
			'Use one record as the anchor and return other items with similar content or attributes.'
	}
];

export function metadataForModel(id: RecommendationModelId): RecommendationModelMetadata {
	return RECOMMENDATION_MODELS.find((model) => model.id === id) ?? RECOMMENDATION_MODELS[0];
}
