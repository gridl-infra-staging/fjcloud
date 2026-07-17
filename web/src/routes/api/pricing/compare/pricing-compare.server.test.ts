import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import type { PricingCompareRequest, PricingCompareResponse } from '$lib/api/types';

const {
	comparePricingMock,
	canonicalComparePricingMock,
	createApiClientMock,
	createCanonicalPublicApiClientMock
} = vi.hoisted(() => {
	const comparePricingMock = vi.fn();
	const canonicalComparePricingMock = vi.fn();
	const createApiClientMock = vi.fn(() => ({
		comparePricing: comparePricingMock
	}));
	const createCanonicalPublicApiClientMock = vi.fn(() => ({
		comparePricing: canonicalComparePricingMock
	}));
	return {
		comparePricingMock,
		canonicalComparePricingMock,
		createApiClientMock,
		createCanonicalPublicApiClientMock
	};
});

vi.mock('$lib/server/api', () => ({
	createApiClient: createApiClientMock,
	createCanonicalPublicApiClient: createCanonicalPublicApiClientMock
}));

import { POST } from './+server';

const workload: PricingCompareRequest = {
	document_count: 100_000,
	avg_document_size_bytes: 2048,
	search_requests_per_month: 1_000_000,
	write_operations_per_month: 50_000,
	sort_directions: 2,
	num_indexes: 1,
	high_availability: false
};

const comparisonResponse: PricingCompareResponse = {
	workload,
	estimates: [
		{
			provider: 'Algolia',
			monthly_total_cents: 50_000,
			line_items: [],
			assumptions: ['Standard pricing'],
			plan_name: 'Pro'
		}
	],
	generated_at: '2026-03-19T00:00:00Z'
};

function makeRequestEvent(body: unknown): unknown {
	return {
		request: new Request('http://localhost/api/pricing/compare', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(body)
		}),
		locals: { user: null },
		params: {}
	} as never;
}

describe('POST /api/pricing/compare', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('allows public access and returns upstream comparison JSON', async () => {
		comparePricingMock.mockResolvedValue(comparisonResponse);

		const response = await POST(makeRequestEvent(workload) as never);
		expect(response.status).toBe(200);
		expect(await response.json()).toEqual(comparisonResponse);
	});

	it('creates createApiClient without an auth token', async () => {
		comparePricingMock.mockResolvedValue(comparisonResponse);

		await POST(makeRequestEvent(workload) as never);

		expect(createApiClientMock).toHaveBeenCalledWith();
	});

	it('passes the request body directly to comparePricing', async () => {
		comparePricingMock.mockResolvedValue(comparisonResponse);

		await POST(makeRequestEvent(workload) as never);

		expect(comparePricingMock).toHaveBeenCalledWith(workload);
	});

	it('returns upstream 400 validation envelopes unchanged', async () => {
		comparePricingMock.mockRejectedValue(
			new ApiRequestError(400, 'document_count must be positive')
		);

		const response = await POST(makeRequestEvent({ ...workload, document_count: -1 }) as never);
		expect(response.status).toBe(400);
		expect(await response.json()).toEqual({ error: 'document_count must be positive' });
	});

	it('returns a generic 500 envelope when upstream returns an ApiRequestError 5xx', async () => {
		comparePricingMock.mockRejectedValue(
			new ApiRequestError(500, 'dial tcp 10.0.0.12: connection refused')
		);

		const response = await POST(makeRequestEvent(workload) as never);
		expect(response.status).toBe(500);
		expect(await response.json()).toEqual({ error: 'pricing compare failed' });
	});

	it('falls back to canonical public pricing API when the configured API is unreachable', async () => {
		comparePricingMock.mockRejectedValue(new TypeError('fetch failed'));
		canonicalComparePricingMock.mockResolvedValue(comparisonResponse);

		const response = await POST(makeRequestEvent(workload) as never);

		expect(response.status).toBe(200);
		expect(createCanonicalPublicApiClientMock).toHaveBeenCalledWith();
		expect(canonicalComparePricingMock).toHaveBeenCalledWith(workload);
		expect(await response.json()).toEqual(comparisonResponse);
	});

	it('returns 500 with a generic error envelope for unexpected upstream failures', async () => {
		comparePricingMock.mockRejectedValue(new Error('pricing backend timeout'));

		const response = await POST(makeRequestEvent(workload) as never);
		expect(response.status).toBe(500);
		expect(createCanonicalPublicApiClientMock).not.toHaveBeenCalled();
		expect(await response.json()).toEqual({ error: 'pricing compare failed' });
	});
});
