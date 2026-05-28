import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import { createApiClient } from '$lib/server/api';
import { makeActionArgs } from './detail.server.test.shared';

// ---------------------------------------------------------------------------
// Mock function references (must be declared before vi.mock)
// ---------------------------------------------------------------------------

const savePersonalizationStrategyMock = vi.fn();
const deletePersonalizationStrategyMock = vi.fn();
const getPersonalizationProfileMock = vi.fn();
const deletePersonalizationProfileMock = vi.fn();
const recommendMock = vi.fn();
const chatMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		savePersonalizationStrategy: savePersonalizationStrategyMock,
		deletePersonalizationStrategy: deletePersonalizationStrategyMock,
		getPersonalizationProfile: getPersonalizationProfileMock,
		deletePersonalizationProfile: deletePersonalizationProfileMock,
		recommend: recommendMock,
		chat: chatMock
	}))
}));

// ---------------------------------------------------------------------------
// Module under test (imported AFTER vi.mock)
// ---------------------------------------------------------------------------

import { actions } from './+page.server';

// ---------------------------------------------------------------------------
// Tests — AI/search action handlers (personalization, recommendations, chat)
// ---------------------------------------------------------------------------

describe('Index detail page server -- AI action handlers', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('savePersonalizationStrategy action saves parsed strategy through API client', async () => {
		savePersonalizationStrategyMock.mockResolvedValue(undefined);

		const formData = new FormData();
		formData.set(
			'strategy',
			JSON.stringify({
				eventsScoring: [
					{ eventName: 'Product viewed', eventType: 'view', score: 10 },
					{ eventName: 'Product purchased', eventType: 'conversion', score: 50 }
				],
				facetsScoring: [
					{ facetName: 'brand', score: 70 },
					{ facetName: 'category', score: 30 }
				],
				personalizationImpact: 75
			})
		);

		const result = await actions.savePersonalizationStrategy(
			makeActionArgs('savePersonalizationStrategy', formData) as never
		);

		expect(savePersonalizationStrategyMock).toHaveBeenCalledWith('products', {
			eventsScoring: [
				{ eventName: 'Product viewed', eventType: 'view', score: 10 },
				{ eventName: 'Product purchased', eventType: 'conversion', score: 50 }
			],
			facetsScoring: [
				{ facetName: 'brand', score: 70 },
				{ facetName: 'category', score: 30 }
			],
			personalizationImpact: 75
		});
		expect(createApiClient).toHaveBeenCalledWith('jwt-token');
		expect(result).toEqual({ personalizationStrategySaved: true });
	});

	it('deletePersonalizationStrategy action deletes strategy through API client', async () => {
		deletePersonalizationStrategyMock.mockResolvedValue(undefined);

		const result = await actions.deletePersonalizationStrategy(
			makeActionArgs('deletePersonalizationStrategy', new FormData()) as never
		);

		expect(deletePersonalizationStrategyMock).toHaveBeenCalledWith('products');
		expect(createApiClient).toHaveBeenCalledWith('jwt-token');
		expect(result).toEqual({ personalizationStrategyDeleted: true });
	});

	it('getPersonalizationProfile action loads profile through API client', async () => {
		getPersonalizationProfileMock.mockResolvedValue({
			userToken: 'user_abc',
			lastEventAt: '2026-02-25T00:00:00Z',
			scores: {
				brand: { apple: 20 },
				category: { shoes: 12 }
			}
		});

		const formData = new FormData();
		formData.set('userToken', 'user_abc');

		const result = await actions.getPersonalizationProfile(
			makeActionArgs('getPersonalizationProfile', formData) as never
		);

		expect(getPersonalizationProfileMock).toHaveBeenCalledWith('products', 'user_abc');
		expect(createApiClient).toHaveBeenCalledWith('jwt-token');
		expect(result).toEqual({
			personalizationProfile: {
				userToken: 'user_abc',
				lastEventAt: '2026-02-25T00:00:00Z',
				scores: {
					brand: { apple: 20 },
					category: { shoes: 12 }
				}
			},
			personalizationProfileLookupAttempted: true
		});
	});

	it('deletePersonalizationProfile action deletes profile through API client', async () => {
		deletePersonalizationProfileMock.mockResolvedValue(undefined);

		const formData = new FormData();
		formData.set('userToken', 'user_abc');

		const result = await actions.deletePersonalizationProfile(
			makeActionArgs('deletePersonalizationProfile', formData) as never
		);

		expect(deletePersonalizationProfileMock).toHaveBeenCalledWith('products', 'user_abc');
		expect(createApiClient).toHaveBeenCalledWith('jwt-token');
		expect(result).toEqual({
			personalizationProfileDeleted: true,
			personalizationProfile: null,
			personalizationProfileLookupAttempted: false
		});
	});

	it('getPersonalizationProfile action rejects blank userToken before API call', async () => {
		const formData = new FormData();
		formData.set('userToken', '   ');

		const result = await actions.getPersonalizationProfile(
			makeActionArgs('getPersonalizationProfile', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({ personalizationError: 'userToken is required' })
			})
		);
		expect(getPersonalizationProfileMock).not.toHaveBeenCalled();
	});

	it('recommend action calls API with parsed recommendations batch request', async () => {
		recommendMock.mockResolvedValue({
			results: [
				{
					hits: [{ objectID: 'shoe-1' }, { objectID: 'shoe-2' }],
					processingTimeMS: 4
				}
			]
		});

		const formData = new FormData();
		formData.set(
			'request',
			JSON.stringify({
				requests: [
					{
						indexName: 'attacker-index',
						model: 'related-products',
						objectID: 'shoe-1',
						threshold: 0,
						maxRecommendations: 2
					}
				]
			})
		);

		const result = await actions.recommend(makeActionArgs('recommend', formData) as never);

		expect(recommendMock).toHaveBeenCalledWith('products', {
			requests: [
				{
					indexName: 'products',
					model: 'related-products',
					objectID: 'shoe-1',
					threshold: 0,
					maxRecommendations: 2
				}
			]
		});
		expect(result).toEqual({
			recommendationsResponse: {
				results: [
					{
						hits: [{ objectID: 'shoe-1' }, { objectID: 'shoe-2' }],
						processingTimeMS: 4
					}
				]
			}
		});
	});

	it('recommend action rejects payload without requests array', async () => {
		const formData = new FormData();
		formData.set('request', JSON.stringify({ requests: 'invalid' }));

		const result = await actions.recommend(makeActionArgs('recommend', formData) as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					recommendationsError: 'request.requests must be an array'
				})
			})
		);
		expect(recommendMock).not.toHaveBeenCalled();
	});

	it('recommend action rejects multi-request payloads', async () => {
		const formData = new FormData();
		formData.set(
			'request',
			JSON.stringify({
				requests: [
					{
						indexName: 'products',
						model: 'related-products',
						objectID: 'shoe-1',
						threshold: 0,
						maxRecommendations: 2
					},
					{
						indexName: 'products',
						model: 'related-products',
						objectID: 'shoe-2',
						threshold: 0,
						maxRecommendations: 2
					}
				]
			})
		);

		const result = await actions.recommend(makeActionArgs('recommend', formData) as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					recommendationsError: 'request.requests must contain exactly one request'
				})
			})
		);
		expect(recommendMock).not.toHaveBeenCalled();
	});

	it('recommend action delegates to recommendations-management owner', async () => {
		const recommendActionMock = vi.fn().mockResolvedValue({
			recommendationsResponse: { results: [{ hits: [], processingTimeMS: 1 }] }
		});
		vi.resetModules();
		vi.doMock('./recommendations-management.server', () => ({
			recommendAction: recommendActionMock
		}));

		const { actions: reloadedActions } = await import('./+page.server');
		const actionArgs = makeActionArgs('recommend', new FormData()) as {
			request: Request;
			locals: { user: { token: string } };
			params: { name: string };
		};
		const result = await reloadedActions.recommend(actionArgs as never);

		expect(recommendActionMock).toHaveBeenCalledWith({
			request: actionArgs.request,
			indexName: actionArgs.params.name,
			token: actionArgs.locals.user.token
		});
		expect(result).toEqual({
			recommendationsResponse: { results: [{ hits: [], processingTimeMS: 1 }] }
		});

		vi.doUnmock('./recommendations-management.server');
		vi.resetModules();
	});

	it('chat action delegates to chat-management owner', async () => {
		const chatActionMock = vi.fn().mockResolvedValue({
			chatQuery: 'What should I buy next?',
			chatResponse: {
				answer: 'Try shoe-2',
				sources: [{ objectID: 'shoe-2' }],
				conversationId: 'conv-1',
				queryID: 'q-1'
			}
		});
		vi.resetModules();
		vi.doMock('./chat-management.server', () => ({
			chatAction: chatActionMock
		}));

		const { actions: reloadedActions } = await import('./+page.server');
		const formData = new FormData();
		formData.set('query', 'What should I buy next?');
		const actionArgs = makeActionArgs('chat', formData) as {
			request: Request;
			locals: { user: { token: string } };
			params: { name: string };
		};
		const result = await reloadedActions.chat(actionArgs as never);

		expect(chatActionMock).toHaveBeenCalledWith({
			request: actionArgs.request,
			indexName: actionArgs.params.name,
			token: actionArgs.locals.user.token
		});
		expect(result).toEqual({
			chatQuery: 'What should I buy next?',
			chatResponse: {
				answer: 'Try shoe-2',
				sources: [{ objectID: 'shoe-2' }],
				conversationId: 'conv-1',
				queryID: 'q-1'
			}
		});

		vi.doUnmock('./chat-management.server');
		vi.resetModules();
	});

	it('chat action calls API with query, parsed conversation history, and conversationId', async () => {
		chatMock.mockResolvedValue({
			answer: 'Try shoe-2',
			sources: [{ objectID: 'shoe-2' }],
			conversationId: 'conv-1',
			queryID: 'q-1'
		});

		const formData = new FormData();
		formData.set('query', 'What should I buy next?');
		formData.set('conversationId', 'conv-0');
		formData.set(
			'conversationHistory',
			JSON.stringify([{ role: 'user', content: 'I bought shoe-1' }])
		);

		const result = await actions.chat(makeActionArgs('chat', formData) as never);

		expect(chatMock).toHaveBeenCalledWith('products', {
			query: 'What should I buy next?',
			conversationId: 'conv-0',
			conversationHistory: [{ role: 'user', content: 'I bought shoe-1' }]
		});
		expect(result).toEqual({
			chatQuery: 'What should I buy next?',
			chatResponse: {
				answer: 'Try shoe-2',
				sources: [{ objectID: 'shoe-2' }],
				conversationId: 'conv-1',
				queryID: 'q-1'
			}
		});
	});

	it('chat action rejects blank query', async () => {
		const formData = new FormData();
		formData.set('query', '   ');

		const result = await actions.chat(makeActionArgs('chat', formData) as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({ chatError: 'Query is required' })
			})
		);
		expect(chatMock).not.toHaveBeenCalled();
	});

	it('chat action rejects query longer than maximum allowed length', async () => {
		const formData = new FormData();
		formData.set('query', 'x'.repeat(2001));

		const result = await actions.chat(makeActionArgs('chat', formData) as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					chatError: 'Query must be at most 2000 characters'
				})
			})
		);
		expect(chatMock).not.toHaveBeenCalled();
	});

	it('chat action rejects invalid conversationHistory payload', async () => {
		const formData = new FormData();
		formData.set('query', 'Hello');
		formData.set('conversationHistory', JSON.stringify({ role: 'user', content: 'Hi' }));

		const result = await actions.chat(makeActionArgs('chat', formData) as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					chatError: 'conversationHistory must be a JSON array'
				})
			})
		);
		expect(chatMock).not.toHaveBeenCalled();
	});

	it('chat action rejects conversationHistory longer than maximum allowed entries', async () => {
		const formData = new FormData();
		formData.set('query', 'Hello');
		formData.set(
			'conversationHistory',
			JSON.stringify(Array.from({ length: 101 }, () => ({ role: 'user' })))
		);

		const result = await actions.chat(makeActionArgs('chat', formData) as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					chatError: 'conversationHistory must contain at most 100 entries',
					chatQuery: 'Hello'
				})
			})
		);
		expect(chatMock).not.toHaveBeenCalled();
	});

	it('chat action rejects malformed conversationHistory JSON', async () => {
		const formData = new FormData();
		formData.set('query', 'Hello');
		formData.set('conversationHistory', '{not-json');

		const result = await actions.chat(makeActionArgs('chat', formData) as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					chatError: 'conversationHistory must be valid JSON',
					chatQuery: 'Hello'
				})
			})
		);
		expect(chatMock).not.toHaveBeenCalled();
	});

	it('chat action trims query and keeps conversationId optional in API payload', async () => {
		chatMock.mockResolvedValue({
			answer: 'Ask about socks too',
			sources: [],
			conversationId: 'conv-2',
			queryID: 'q-2'
		});

		const formData = new FormData();
		formData.set('query', '   Recommend socks   ');
		formData.set('conversationId', '   ');
		formData.set('conversationHistory', '   ');

		const result = await actions.chat(makeActionArgs('chat', formData) as never);

		expect(chatMock).toHaveBeenCalledWith('products', {
			query: 'Recommend socks',
			conversationHistory: []
		});
		expect(result).toEqual({
			chatQuery: 'Recommend socks',
			chatResponse: {
				answer: 'Ask about socks too',
				sources: [],
				conversationId: 'conv-2',
				queryID: 'q-2'
			}
		});
	});

	it('savePersonalizationStrategy action returns fail on invalid JSON', async () => {
		const formData = new FormData();
		formData.set('strategy', '{ broken json');

		const result = await actions.savePersonalizationStrategy(
			makeActionArgs('savePersonalizationStrategy', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					personalizationError: expect.stringContaining('valid JSON')
				})
			})
		);
		expect(savePersonalizationStrategyMock).not.toHaveBeenCalled();
	});

	it('savePersonalizationStrategy action rejects unsupported eventType enum values', async () => {
		const formData = new FormData();
		formData.set(
			'strategy',
			JSON.stringify({
				eventsScoring: [{ eventName: 'Product viewed', eventType: 'purchase', score: 10 }],
				facetsScoring: [{ facetName: 'brand', score: 70 }],
				personalizationImpact: 75
			})
		);

		const result = await actions.savePersonalizationStrategy(
			makeActionArgs('savePersonalizationStrategy', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					personalizationError: 'Invalid strategy JSON'
				})
			})
		);
		expect(savePersonalizationStrategyMock).not.toHaveBeenCalled();
	});

	it('savePersonalizationStrategy action rejects out-of-bounds integer scores and impact', async () => {
		const formData = new FormData();
		formData.set(
			'strategy',
			JSON.stringify({
				eventsScoring: [{ eventName: 'Product viewed', eventType: 'view', score: 10 }],
				facetsScoring: [{ facetName: 'brand', score: 70 }],
				personalizationImpact: 101
			})
		);

		const result = await actions.savePersonalizationStrategy(
			makeActionArgs('savePersonalizationStrategy', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					personalizationError: expect.stringContaining('must be between')
				})
			})
		);
		expect(savePersonalizationStrategyMock).not.toHaveBeenCalled();
	});

	it('savePersonalizationStrategy action rejects strategy arrays larger than 15 rows', async () => {
		const oversizeEvents = Array.from({ length: 16 }, (_, index) => ({
			eventName: `Event ${index + 1}`,
			eventType: 'view',
			score: 10
		}));
		const oversizeFacets = Array.from({ length: 16 }, (_, index) => ({
			facetName: `facet_${index + 1}`,
			score: 10
		}));
		const formData = new FormData();
		formData.set(
			'strategy',
			JSON.stringify({
				eventsScoring: oversizeEvents,
				facetsScoring: oversizeFacets,
				personalizationImpact: 75
			})
		);

		const result = await actions.savePersonalizationStrategy(
			makeActionArgs('savePersonalizationStrategy', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					personalizationError: expect.stringContaining('at most 15')
				})
			})
		);
		expect(savePersonalizationStrategyMock).not.toHaveBeenCalled();
	});

	it('savePersonalizationStrategy action returns fail on API error', async () => {
		savePersonalizationStrategyMock.mockRejectedValue(new Error('upstream failed'));

		const formData = new FormData();
		formData.set(
			'strategy',
			JSON.stringify({
				eventsScoring: [{ eventName: 'Product viewed', eventType: 'view', score: 10 }],
				facetsScoring: [{ facetName: 'brand', score: 70 }],
				personalizationImpact: 75
			})
		);

		const result = await actions.savePersonalizationStrategy(
			makeActionArgs('savePersonalizationStrategy', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({ personalizationError: 'upstream failed' })
			})
		);
	});

	it('deletePersonalizationProfile action rejects blank userToken', async () => {
		const formData = new FormData();
		formData.set('userToken', '');

		const result = await actions.deletePersonalizationProfile(
			makeActionArgs('deletePersonalizationProfile', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({ personalizationError: 'userToken is required' })
			})
		);
		expect(deletePersonalizationProfileMock).not.toHaveBeenCalled();
	});

	it('recommend action returns fail when request body is empty', async () => {
		const formData = new FormData();

		const result = await actions.recommend(makeActionArgs('recommend', formData) as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					recommendationsError: 'Recommendations JSON is required'
				})
			})
		);
		expect(recommendMock).not.toHaveBeenCalled();
	});

	it('recommend action returns fail on API error', async () => {
		recommendMock.mockRejectedValue(new Error('upstream failed'));

		const formData = new FormData();
		formData.set(
			'request',
			JSON.stringify({
				requests: [
					{
						indexName: 'products',
						model: 'trending-items',
						threshold: 0,
						maxRecommendations: 3
					}
				]
			})
		);

		const result = await actions.recommend(makeActionArgs('recommend', formData) as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({ recommendationsError: 'upstream failed' })
			})
		);
	});

	it('recommend action returns shared session failure for 401 upstream auth errors', async () => {
		recommendMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const formData = new FormData();
		formData.set(
			'request',
			JSON.stringify({
				requests: [
					{
						indexName: 'products',
						model: 'trending-items',
						threshold: 0,
						maxRecommendations: 3
					}
				]
			})
		);

		const result = await actions.recommend(makeActionArgs('recommend', formData) as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 401,
				data: expect.objectContaining({
					_authSessionExpired: true,
					error: 'Unauthorized'
				})
			})
		);
	});

	it('chat action returns fail on API error', async () => {
		chatMock.mockRejectedValue(new Error('upstream failed'));

		const formData = new FormData();
		formData.set('query', 'What should I buy?');

		const result = await actions.chat(makeActionArgs('chat', formData) as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					chatError: 'upstream failed',
					chatQuery: 'What should I buy?'
				})
			})
		);
	});

	it('chat action returns shared session failure for 401 upstream auth errors', async () => {
		chatMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const formData = new FormData();
		formData.set('query', 'What should I buy?');

		const result = await actions.chat(makeActionArgs('chat', formData) as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 401,
				data: expect.objectContaining({
					_authSessionExpired: true,
					error: 'Unauthorized'
				})
			})
		);
	});
});
