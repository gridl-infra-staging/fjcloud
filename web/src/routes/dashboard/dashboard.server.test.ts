import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import type { UsageSummaryResponse, Index, FreeTierLimits } from '$lib/api/types';

const getUsageMock = vi.fn();
const getUsageDailyMock = vi.fn();
const getIndexesMock = vi.fn();
const getEstimatedBillMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		getUsage: getUsageMock,
		getUsageDaily: getUsageDailyMock,
		getIndexes: getIndexesMock,
		getEstimatedBill: getEstimatedBillMock
	}))
}));

import { load } from './+page.server';

const freeTierLimits: FreeTierLimits = {
	max_searches_per_month: 50000,
	max_records: 100000,
	max_storage_gb: 10,
	max_indexes: 1
};

const sampleUsage: UsageSummaryResponse = {
	month: '2026-02',
	total_search_requests: 15234,
	total_write_operations: 4567,
	avg_storage_gb: 2.5,
	avg_document_count: 89012,
	by_region: []
};

const sampleIndexes: Index[] = [
	{
		name: 'products',
		region: 'us-east-1',
		endpoint: 'https://vm-abc.flapjack.foo',
		entries: 1500,
		data_size_bytes: 204800,
		status: 'ready',
		tier: 'active',
		created_at: '2026-02-15T10:00:00Z'
	}
];

const freePlanContext = {
	billing_plan: 'free' as const,
	free_tier_limits: freeTierLimits,
	has_payment_method: false,
	onboarding_completed: false
};

const sharedPlanContext = {
	billing_plan: 'shared' as const,
	free_tier_limits: null as FreeTierLimits | null,
	has_payment_method: true,
	onboarding_completed: true
};

describe('Dashboard page server load', () => {
	let parentMock: ReturnType<typeof vi.fn>;

	beforeEach(() => {
		vi.clearAllMocks();
		parentMock = vi.fn().mockResolvedValue({ planContext: freePlanContext });
		getUsageMock.mockResolvedValue(sampleUsage);
		getUsageDailyMock.mockResolvedValue([]);
		getIndexesMock.mockResolvedValue(sampleIndexes);
		getEstimatedBillMock.mockRejectedValue(new Error('no rate card'));
	});

	function event(opts: {
		planContext?: typeof freePlanContext | typeof sharedPlanContext;
		month?: string;
	} = {}) {
		if (opts.planContext) {
			parentMock.mockResolvedValue({ planContext: opts.planContext });
		}
		const url = new URL('http://localhost/dashboard');
		if (opts.month) url.searchParams.set('month', opts.month);
		return {
			locals: { user: { customerId: 'cust-1', token: 'jwt-tok' } },
			url,
			parent: parentMock
		} as never;
	}

	it('calls parent() to access layout plan context', async () => {
		await load(event());
		expect(parentMock).toHaveBeenCalledOnce();
	});

	it('derives freeTierProgress from usage and free_tier_limits', async () => {
		const result = (await load(event()))!;

		expect(result.freeTierProgress).toEqual({
			searches: { used: 15234, limit: 50000 },
			records: { used: 89012, limit: 100000 },
			storage_gb: { used: 2.5, limit: 10 },
			indexes: { used: 1, limit: 1 }
		});
	});

	it('returns freeTierProgress as null for shared plan', async () => {
		const result = (await load(event({ planContext: sharedPlanContext })))!;
		expect(result.freeTierProgress).toBeNull();
	});

	it('does not return onboardingStatus (layout owns it)', async () => {
		const result = (await load(event()))!;
		expect(result).not.toHaveProperty('onboardingStatus');
	});

	it('indexes count in freeTierProgress reflects fetched indexes', async () => {
		getIndexesMock.mockResolvedValue([
			...sampleIndexes,
			{ ...sampleIndexes[0], name: 'blog-posts' }
		]);

		const result = (await load(event()))!;
		expect(result.freeTierProgress!.indexes.used).toBe(2);
	});

	it('returns usage, dailyUsage, indexes, estimate, and month', async () => {
		const result = (await load(event()))!;

		expect(result.usage).toEqual(sampleUsage);
		expect(result.dailyUsage).toEqual([]);
		expect(result.indexes).toEqual(sampleIndexes);
		expect(result.month).toBe('2026-02');
		expect(result.estimate).toBeNull();
	});

	it('retries transient getIndexes failures before falling back to the dashboard payload', async () => {
		getIndexesMock
			.mockRejectedValueOnce(new ApiRequestError(429, 'too many requests'))
			.mockRejectedValueOnce(new ApiRequestError(503, 'service unavailable'))
			.mockResolvedValueOnce(sampleIndexes);

		const result = (await load(event()))!;

		expect(getIndexesMock).toHaveBeenCalledTimes(3);
		expect(result.indexes).toEqual(sampleIndexes);
	});

	it('graceful fallback returns null freeTierProgress', async () => {
		getUsageMock.mockRejectedValue(new Error('service error'));
		getUsageDailyMock.mockRejectedValue(new Error('service error'));

		const result = (await load(event()))!;
		expect(result.freeTierProgress).toBeNull();
	});
});
