import { describe, expect, it } from 'vitest';
import {
	DEFAULT_RECOMMENDATION_MODEL,
	RECOMMENDATION_MODELS,
	metadataForModel
} from './model_metadata';

describe('model_metadata', () => {
	it('defines exactly five supported models in stable order', () => {
		expect(RECOMMENDATION_MODELS.map((model) => model.id)).toEqual([
			'related-products',
			'bought-together',
			'trending-items',
			'trending-facets',
			'looking-similar'
		]);
	});

	it('uses related-products as the default model id', () => {
		expect(DEFAULT_RECOMMENDATION_MODEL).toBe('related-products');
	});

	it('returns requirement flags per model id', () => {
		expect(metadataForModel('related-products')).toMatchObject({
			requiresObjectID: true,
			requiresFacetName: false
		});
		expect(metadataForModel('bought-together')).toMatchObject({
			requiresObjectID: true,
			requiresFacetName: false
		});
		expect(metadataForModel('trending-items')).toMatchObject({
			requiresObjectID: false,
			requiresFacetName: false
		});
		expect(metadataForModel('trending-facets')).toMatchObject({
			requiresObjectID: false,
			requiresFacetName: true
		});
		expect(metadataForModel('looking-similar')).toMatchObject({
			requiresObjectID: true,
			requiresFacetName: false
		});
	});
});
