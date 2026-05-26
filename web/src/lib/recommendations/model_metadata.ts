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
};

export const DEFAULT_RECOMMENDATION_MODEL: RecommendationModelId = 'related-products';

export const RECOMMENDATION_MODELS: RecommendationModelMetadata[] = [
	{
		id: 'related-products',
		label: 'Related Products',
		requiresObjectID: true,
		requiresFacetName: false
	},
	{
		id: 'bought-together',
		label: 'Bought Together',
		requiresObjectID: true,
		requiresFacetName: false
	},
	{
		id: 'trending-items',
		label: 'Trending Items',
		requiresObjectID: false,
		requiresFacetName: false
	},
	{
		id: 'trending-facets',
		label: 'Trending Facets',
		requiresObjectID: false,
		requiresFacetName: true
	},
	{
		id: 'looking-similar',
		label: 'Looking Similar',
		requiresObjectID: true,
		requiresFacetName: false
	}
];

export function metadataForModel(id: RecommendationModelId): RecommendationModelMetadata {
	return RECOMMENDATION_MODELS.find((model) => model.id === id) ?? RECOMMENDATION_MODELS[0];
}
