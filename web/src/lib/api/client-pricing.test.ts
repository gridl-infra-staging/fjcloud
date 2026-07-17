import { describe, it, expect, beforeEach } from 'vitest';
import { ApiClient } from './client';
import type { PricingCompareRequest, PricingCompareResponse } from './types';
import { BASE_URL, mockFetch, createClient, createAuthenticatedClient } from './client.test.shared';

// Pricing comparison is a public endpoint (no auth). Extracted from
// client.test.ts to keep that file under the 800-line size cap.
describe('ApiClient pricing comparison (public)', () => {
	let client: ApiClient;

	beforeEach(() => {
		client = createClient();
	});

	const validWorkload: PricingCompareRequest = {
		document_count: 100_000,
		avg_document_size_bytes: 2048,
		search_requests_per_month: 1_000_000,
		write_operations_per_month: 50_000,
		sort_directions: 2,
		num_indexes: 1,
		high_availability: false
	};

	const sampleResponse: PricingCompareResponse = {
		workload: validWorkload,
		estimates: [
			{
				provider: 'Algolia',
				monthly_total_cents: 50000,
				line_items: [
					{
						description: 'Search requests',
						quantity: '1000.0',
						unit: 'searches_1k',
						unit_price_cents: '50',
						amount_cents: 50000
					}
				],
				assumptions: ['Standard pricing'],
				plan_name: 'Pro'
			}
		],
		generated_at: '2026-03-18T00:00:00Z'
	};

	it('POST /pricing/compare sends workload and returns comparison result', async () => {
		const fetch = mockFetch(200, sampleResponse);
		client.setFetch(fetch);

		const result = await client.comparePricing(validWorkload);

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/pricing/compare`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(validWorkload)
		});
		expect(result).toEqual(sampleResponse);
	});

	it('POST /pricing/compare omits auth header even for an authenticated client', async () => {
		const authenticatedClient = createAuthenticatedClient();
		const fetch = mockFetch(200, sampleResponse);
		authenticatedClient.setFetch(fetch);

		await authenticatedClient.comparePricing(validWorkload);

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/pricing/compare`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(validWorkload)
		});
	});

	it('response contains estimates sorted cheapest-first', async () => {
		const multiEstimateResponse: PricingCompareResponse = {
			workload: validWorkload,
			estimates: [
				{
					provider: 'TypesenseCloud',
					monthly_total_cents: 3000,
					line_items: [],
					assumptions: [],
					plan_name: null
				},
				{
					provider: 'Algolia',
					monthly_total_cents: 50000,
					line_items: [],
					assumptions: [],
					plan_name: 'Pro'
				}
			],
			generated_at: '2026-03-18T00:00:00Z'
		};
		const fetch = mockFetch(200, multiEstimateResponse);
		client.setFetch(fetch);

		const result = await client.comparePricing(validWorkload);

		expect(result.estimates.length).toBeGreaterThanOrEqual(2);
		for (let i = 1; i < result.estimates.length; i++) {
			expect(result.estimates[i].monthly_total_cents).toBeGreaterThanOrEqual(
				result.estimates[i - 1].monthly_total_cents
			);
		}
	});

	it('throws ApiRequestError on 400 validation error', async () => {
		const fetch = mockFetch(400, { error: 'document_count must be positive' });
		client.setFetch(fetch);

		await expect(
			client.comparePricing({ ...validWorkload, document_count: -1 })
		).rejects.toMatchObject({
			name: 'ApiRequestError',
			status: 400,
			message: 'document_count must be positive'
		});
	});

	it('throws ApiRequestError on 422 for malformed request', async () => {
		const fetch = mockFetch(422, { error: 'missing required fields' });
		client.setFetch(fetch);

		// Simulate a partial workload that would fail server-side
		await expect(client.comparePricing(validWorkload)).rejects.toMatchObject({
			name: 'ApiRequestError',
			status: 422
		});
	});
});
