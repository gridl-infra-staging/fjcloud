import { describe, it, expect, beforeEach } from 'vitest';
import { ApiClient } from './client';
import type {
	CreateExperimentRequest,
	ConcludeExperimentRequest,
	Experiment,
	ExperimentActionResponse,
	ExperimentListResponse,
	ExperimentResults,
	DebugEventsResponse
} from './types';
import { BASE_URL, mockFetch, createAuthenticatedClient } from './client.test.shared';

describe('ApiClient - analytics and experiments', () => {
	let client: ApiClient;

	beforeEach(() => {
		client = createAuthenticatedClient();
	});

	describe('analytics endpoints', () => {
		it('GET /indexes/:name/analytics/searches sends date params', async () => {
			const expected = {
				searches: [{ search: 'laptop', count: 42, nbHits: 15 }]
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getAnalyticsTopSearches('products', {
				startDate: '2026-02-18',
				endDate: '2026-02-25',
				limit: 10
			});

			expect(fetch).toHaveBeenCalledWith(
				`${BASE_URL}/indexes/products/analytics/searches?startDate=2026-02-18&endDate=2026-02-25&limit=10`,
				{
					method: 'GET',
					headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
				}
			);
			expect(result).toEqual(expected);
		});

		it('GET /indexes/:name/analytics/searches/count sends date params', async () => {
			const expected = {
				count: 1234,
				dates: [{ date: '2026-02-24', count: 180 }]
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getAnalyticsSearchCount('products', {
				startDate: '2026-02-18',
				endDate: '2026-02-25'
			});

			expect(fetch).toHaveBeenCalledWith(
				`${BASE_URL}/indexes/products/analytics/searches/count?startDate=2026-02-18&endDate=2026-02-25`,
				{
					method: 'GET',
					headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
				}
			);
			expect(result).toEqual(expected);
		});

		it('GET /indexes/:name/analytics/searches/noResults sends date params', async () => {
			const expected = {
				searches: [{ search: 'lapptop', count: 8, nbHits: 0 }]
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getAnalyticsNoResults('products', {
				startDate: '2026-02-18',
				endDate: '2026-02-25',
				limit: 10
			});

			expect(fetch).toHaveBeenCalledWith(
				`${BASE_URL}/indexes/products/analytics/searches/noResults?startDate=2026-02-18&endDate=2026-02-25&limit=10`,
				{
					method: 'GET',
					headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
				}
			);
			expect(result).toEqual(expected);
		});

		it('GET /indexes/:name/analytics/searches/noResultRate sends date params', async () => {
			const expected = {
				rate: 0.12,
				count: 1234,
				noResults: 148,
				dates: [{ date: '2026-02-24', rate: 0.1, count: 180, noResults: 18 }]
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getAnalyticsNoResultRate('products', {
				startDate: '2026-02-18',
				endDate: '2026-02-25'
			});

			expect(fetch).toHaveBeenCalledWith(
				`${BASE_URL}/indexes/products/analytics/searches/noResultRate?startDate=2026-02-18&endDate=2026-02-25`,
				{
					method: 'GET',
					headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
				}
			);
			expect(result).toEqual(expected);
		});

		it('GET /indexes/:name/analytics/status returns status', async () => {
			const expected = { indexName: 'products', enabled: true };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getAnalyticsStatus('products');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/analytics/status`, {
				method: 'GET',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
			});
			expect(result).toEqual(expected);
		});
	});

	describe('experiment endpoints', () => {
		it('GET /indexes/:name/experiments returns experiments list', async () => {
			const expected: ExperimentListResponse = {
				abtests: [
					{
						abTestID: 7,
						name: 'Ranking test',
						status: 'created',
						endAt: '2026-03-15T00:00:00Z',
						createdAt: '2026-02-25T00:00:00Z',
						updatedAt: '2026-02-25T00:00:00Z',
						variants: [{ index: 'products', trafficPercentage: 50 }],
						configuration: { minimumDetectableEffect: { size: 0.05 } }
					}
				],
				count: 1,
				total: 1
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.listExperiments('products');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/experiments`, {
				method: 'GET',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
			});
			expect(result).toEqual(expected);
		});

		it('POST /indexes/:name/experiments sends create body', async () => {
			const requestBody: CreateExperimentRequest = {
				name: 'Ranking test',
				variants: [
					{ index: 'products', trafficPercentage: 50 },
					{ index: 'products', trafficPercentage: 50, customSearchParameters: { enableRules: false } }
				],
				configuration: {
					minimumDetectableEffect: { size: 0.05 },
					outliers: { exclude: true },
					emptySearch: { exclude: true }
				}
			};
			const expected: ExperimentActionResponse = { abTestID: 7, index: 'products', taskID: 101 };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.createExperiment('products', requestBody);

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/experiments`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
				body: JSON.stringify(requestBody)
			});
			expect(result).toEqual(expected);
		});

		it('GET /indexes/:name/experiments/:id returns one experiment', async () => {
			const expected: Experiment = {
				abTestID: 7,
				name: 'Ranking test',
				status: 'running',
				endAt: '2026-03-15T00:00:00Z',
				createdAt: '2026-02-25T00:00:00Z',
				updatedAt: '2026-02-25T00:00:00Z',
				variants: [{ index: 'products', trafficPercentage: 50 }],
				configuration: {}
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getExperiment('products', 7);

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/experiments/7`, {
				method: 'GET',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
			});
			expect(result).toEqual(expected);
		});

		it('DELETE /indexes/:name/experiments/:id sends delete request', async () => {
			const expected: ExperimentActionResponse = { abTestID: 7, index: 'products', taskID: 102 };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.deleteExperiment('products', 7);

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/experiments/7`, {
				method: 'DELETE',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
			});
			expect(result).toEqual(expected);
		});

		it('POST /indexes/:name/experiments/:id/start sends start request', async () => {
			const expected: ExperimentActionResponse = { abTestID: 7, index: 'products', taskID: 103 };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.startExperiment('products', 7);

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/experiments/7/start`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
				body: undefined
			});
			expect(result).toEqual(expected);
		});

		it('POST /indexes/:name/experiments/:id/stop sends stop request', async () => {
			const expected: ExperimentActionResponse = { abTestID: 7, index: 'products', taskID: 104 };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.stopExperiment('products', 7);

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/experiments/7/stop`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
				body: undefined
			});
			expect(result).toEqual(expected);
		});

		it('POST /indexes/:name/experiments/:id/conclude sends conclude body', async () => {
			const requestBody: ConcludeExperimentRequest = {
				winner: 'variant',
				reason: 'variant has better ctr',
				controlMetric: 0.05,
				variantMetric: 0.08,
				confidence: 0.97,
				significant: true,
				promoted: false
			};
			const expected: ExperimentActionResponse = { abTestID: 7, index: 'products', taskID: 105 };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.concludeExperiment('products', 7, requestBody);

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/experiments/7/conclude`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
				body: JSON.stringify(requestBody)
			});
			expect(result).toEqual(expected);
		});

		it('GET /indexes/:name/experiments/:id/results returns experiment results', async () => {
			const expected: ExperimentResults = {
				experimentID: '7',
				name: 'Ranking test',
				status: 'running',
				indexName: 'products',
				trafficSplit: 0.5,
				gate: {
					minimumNReached: true,
					minimumDaysReached: true,
					readyToRead: true,
					requiredSearchesPerArm: 1000,
					currentSearchesPerArm: 1200,
					progressPct: 100
				},
				control: {
					name: 'control',
					searches: 1200,
					users: 500,
					clicks: 140,
					conversions: 55,
					revenue: 0,
					ctr: 0.12,
					conversionRate: 0.04,
					revenuePerSearch: 0,
					zeroResultRate: 0.03,
					abandonmentRate: 0.14,
					meanClickRank: 3.2
				},
				variant: {
					name: 'variant',
					searches: 1200,
					users: 490,
					clicks: 160,
					conversions: 60,
					revenue: 0,
					ctr: 0.13,
					conversionRate: 0.05,
					revenuePerSearch: 0,
					zeroResultRate: 0.02,
					abandonmentRate: 0.12,
					meanClickRank: 2.8
				},
				primaryMetric: 'ctr',
				sampleRatioMismatch: false,
				guardRailAlerts: [],
				cupedApplied: true
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getExperimentResults('products', 7);

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/experiments/7/results`, {
				method: 'GET',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
			});
			expect(result).toEqual(expected);
		});
	});

	describe('debug events endpoints', () => {
		it('GET /indexes/:name/events/debug returns debug events', async () => {
			const expected: DebugEventsResponse = {
				events: [
					{
						timestampMs: 1709251200000,
						index: 'products',
						eventType: 'view',
						eventSubtype: null,
						eventName: 'Viewed Product',
						userToken: 'user_abc',
						objectIds: ['obj1', 'obj2'],
						httpCode: 200,
						validationErrors: []
					}
				],
				count: 1
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getDebugEvents('products');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/events/debug`, {
				method: 'GET',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
			});
			expect(result).toEqual(expected);
		});

		it('GET /indexes/:name/events/debug sends filter params as query string', async () => {
			const expected: DebugEventsResponse = { events: [], count: 0 };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getDebugEvents('products', {
				eventType: 'click',
				status: 'error',
				limit: 50,
				from: 1709251200000,
				until: 1709337600000
			});

			expect(fetch).toHaveBeenCalledWith(
				`${BASE_URL}/indexes/products/events/debug?eventType=click&status=error&limit=50&from=1709251200000&until=1709337600000`,
				{
					method: 'GET',
					headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
				}
			);
			expect(result).toEqual(expected);
		});
	});
});
