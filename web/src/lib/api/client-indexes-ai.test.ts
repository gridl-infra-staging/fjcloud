import { describe, it, expect, beforeEach } from 'vitest';
import { ApiClient } from './client';
import type {
	PersonalizationStrategy,
	PersonalizationProfile,
	RecommendationsBatchRequest,
	RecommendationsBatchResponse,
	IndexChatRequest,
	IndexChatResponse
} from './types';
import { BASE_URL, mockFetch, createAuthenticatedClient } from './client.test.shared';

describe('ApiClient - index AI endpoints', () => {
	let client: ApiClient;

	beforeEach(() => {
		client = createAuthenticatedClient();
	});

	it('GET /indexes/:name/personalization/strategy returns strategy', async () => {
		const expected: PersonalizationStrategy = {
			eventsScoring: [{ eventName: 'Product viewed', eventType: 'view', score: 10 }],
			facetsScoring: [{ facetName: 'brand', score: 70 }],
			personalizationImpact: 75
		};
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.getPersonalizationStrategy('products');

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/personalization/strategy`, {
			method: 'GET',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
		});
		expect(result).toEqual(expected);
	});

	it('PUT /indexes/:name/personalization/strategy sends strategy body', async () => {
		const requestBody: PersonalizationStrategy = {
			eventsScoring: [
				{ eventName: 'Product viewed', eventType: 'view', score: 10 },
				{ eventName: 'Product purchased', eventType: 'conversion', score: 50 }
			],
			facetsScoring: [
				{ facetName: 'brand', score: 70 },
				{ facetName: 'category', score: 30 }
			],
			personalizationImpact: 75
		};
		const expected = { updatedAt: '2026-03-17T00:00:00Z' };
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.savePersonalizationStrategy('products', requestBody);

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/personalization/strategy`, {
			method: 'PUT',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
			body: JSON.stringify(requestBody)
		});
		expect(result).toEqual(expected);
	});

	it('DELETE /indexes/:name/personalization/strategy deletes strategy', async () => {
		const expected = { deletedAt: '2026-03-17T00:00:00Z' };
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.deletePersonalizationStrategy('products');

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/personalization/strategy`, {
			method: 'DELETE',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
		});
		expect(result).toEqual(expected);
	});

	it('GET /indexes/:name/personalization/profiles/:userToken encodes token in URL', async () => {
		const expected: PersonalizationProfile = {
			userToken: 'user token/1',
			lastEventAt: '2026-02-25T00:00:00Z',
			scores: {
				brand: { acme: 20 },
				category: { shoes: 12 }
			}
		};
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.getPersonalizationProfile('products', 'user token/1');

		expect(fetch).toHaveBeenCalledWith(
			`${BASE_URL}/indexes/products/personalization/profiles/user%20token%2F1`,
			{
				method: 'GET',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				}
			}
		);
		expect(result).toEqual(expected);
	});

	it('DELETE /indexes/:name/personalization/profiles/:userToken encodes token in URL', async () => {
		const expected = { userToken: 'user token/1', deletedUntil: '2026-03-17T00:00:00Z' };
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.deletePersonalizationProfile('products', 'user token/1');

		expect(fetch).toHaveBeenCalledWith(
			`${BASE_URL}/indexes/products/personalization/profiles/user%20token%2F1`,
			{
				method: 'DELETE',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				}
			}
		);
		expect(result).toEqual(expected);
	});

	it('POST /indexes/:name/recommendations sends batched recommendation request', async () => {
		const requestBody: RecommendationsBatchRequest = {
			requests: [
				{
					indexName: 'products',
					model: 'trending-items',
					threshold: 0
				}
			]
		};
		const expected: RecommendationsBatchResponse = {
			results: [{ hits: [{ objectID: 'sku-1' }], processingTimeMS: 2 }]
		};
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.recommend('products', requestBody);

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/recommendations`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
			body: JSON.stringify(requestBody)
		});
		expect(result).toEqual(expected);
	});

	it('POST /indexes/:name/chat sends non-streaming chat request', async () => {
		const requestBody: IndexChatRequest = {
			query: 'What should I buy?',
			conversationHistory: []
		};
		const expected: IndexChatResponse = {
			answer: 'Try item A.',
			sources: [{ objectID: 'sku-1' }],
			conversationId: 'conv-123',
			queryID: 'q-123'
		};
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.chat('products', requestBody);

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/chat`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
			body: JSON.stringify(requestBody)
		});
		expect(result).toEqual(expected);
	});

	it('IndexChatRequest does not allow stream toggles', () => {
		// @ts-expect-error IndexChatRequest is JSON-only for Stage 2.
		const invalidRequest: IndexChatRequest = { query: 'hi', stream: true };
		expect(invalidRequest.query).toBe('hi');
	});
});
